import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/notifications/push_registration.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/token_store.dart';

import 'support/factories.dart';

/// Token store backed by memory so logout can be exercised without the platform
/// keychain.
class _MemoryTokenStore extends TokenStore {
  _MemoryTokenStore({this.access, this.refresh, this.userId});

  String? access;
  String? refresh;
  String? userId;

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<String?> readUserId() async => userId;

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    userId = null;
  }
}

/// A Dio adapter that fails every request, standing in for an unreachable
/// backend.
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'offline',
    );
  }
}

/// Records connect/disconnect calls instead of opening a real socket.
class _FakeSocket extends ChatSocket {
  _FakeSocket(super.dao, super.api, super.tokenStore);

  int connects = 0;
  int disconnects = 0;
  bool throwOnDisconnect = false;
  bool hangOnDisconnect = false;

  @override
  Future<void> connect() async {
    connects += 1;
  }

  @override
  Future<void> disconnect() async {
    disconnects += 1;
    if (hangOnDisconnect) return Completer<void>().future;
    if (throwOnDisconnect) throw StateError('socket teardown failed');
  }
}

/// Answers the logout call without a network and can be told to fail or stall.
class _FakeApi extends ApiClient {
  _FakeApi(super.store);

  int logouts = 0;
  bool throwOnLogout = false;
  bool hangOnLogout = false;

  @override
  Future<void> logout() async {
    logouts += 1;
    if (hangOnLogout) return Completer<void>().future;
    if (throwOnLogout) throw StateError('logout request failed');
  }
}

class _FakeE2ee extends E2eeManager {
  _FakeE2ee(TokenStore store, ApiClient api) : super(tokenStore: store, api: api);

  int bootstraps = 0;
  int resets = 0;

  @override
  Future<void> bootstrap() async {
    bootstraps += 1;
  }

  @override
  void reset() {
    resets += 1;
  }
}

class _FakePush extends PushRegistration {
  _FakePush(super.api);

  int starts = 0;
  int stops = 0;

  @override
  Future<void> start() async {
    starts += 1;
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }
}

/// Exposes a way to drive the auth state from a test without a network login.
class _FakeAuth extends AuthController {
  @override
  AuthSession? build() => null;

  void emit(AuthSession? session) => state = session;
}

AuthSession _session() => AuthSession(
      user: const User(id: 'me', name: 'Me'),
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresIn: 900,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late _FakeApi api;
  late _FakeSocket socket;
  late _FakeE2ee e2ee;
  late _FakePush push;
  late ProviderContainer container;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final dao = ChatDao(database);
    final store = _MemoryTokenStore();
    api = _FakeApi(store);
    socket = _FakeSocket(dao, api, store);
    e2ee = _FakeE2ee(store, api);
    push = _FakePush(api);

    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        apiClientProvider.overrideWithValue(api),
        chatSocketProvider.overrideWithValue(socket),
        e2eeManagerProvider.overrideWithValue(e2ee),
        pushRegistrationProvider.overrideWithValue(push),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('signing in starts the socket, E2EE bootstrap, and push registration', () async {
    // Constructing the runtime subscribes it to auth transitions.
    container.read(sessionRuntimeProvider);

    (container.read(authControllerProvider.notifier) as _FakeAuth).emit(_session());
    await settle();

    expect(socket.connects, 1);
    expect(e2ee.bootstraps, 1);
    expect(push.starts, 1);
  });

  test('signing out disconnects the socket and resets E2EE state', () async {
    container.read(sessionRuntimeProvider);
    final auth = container.read(authControllerProvider.notifier) as _FakeAuth;
    auth.emit(_session());
    await settle();

    auth.emit(null);
    await settle();

    expect(socket.disconnects, 1);
    expect(e2ee.resets, 1);
    expect(push.stops, 1);
  });

  test('an explicit start is a no-op while signed out', () async {
    await container.read(sessionRuntimeProvider.notifier).start();
    expect(socket.connects, 0);
  });

  group('logout resilience', () {
    Future<_FakeAuth> signIn() async {
      container.read(sessionRuntimeProvider);
      final auth = container.read(authControllerProvider.notifier) as _FakeAuth;
      auth.emit(_session());
      await settle();
      return auth;
    }

    test('clears state and local data even when the logout request throws', () async {
      final auth = await signIn();
      api.throwOnLogout = true;
      await container
          .read(chatDaoProvider)
          .upsertConversations([conversation('conv-1', selfId: 'me')]);

      await auth.logout();

      expect(container.read(authControllerProvider), isNull);
      expect(await container.read(chatDaoProvider).conversations(), isEmpty);
    });

    test('clears state even when the socket teardown throws', () async {
      final auth = await signIn();
      socket.throwOnDisconnect = true;

      await auth.logout();

      expect(container.read(authControllerProvider), isNull);
    });

    test('does not hang when a teardown step stalls', () async {
      final auth = await signIn();
      auth.logoutStepTimeout = const Duration(milliseconds: 50);
      socket.hangOnDisconnect = true;

      await auth.logout();

      expect(container.read(authControllerProvider), isNull);
    });

    test('ApiClient.logout clears tokens even when the server is unreachable', () async {
      final store = _MemoryTokenStore(access: 'a', refresh: 'r', userId: 'me');
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..httpClientAdapter = _ThrowingAdapter();

      await ApiClient(store, dio: dio).logout();

      expect(store.access, isNull);
      expect(store.refresh, isNull);
      expect(store.userId, isNull);
    });
  });
}
