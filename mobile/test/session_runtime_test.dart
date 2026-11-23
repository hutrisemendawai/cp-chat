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

/// Records connect/disconnect calls instead of opening a real socket.
class _FakeSocket extends ChatSocket {
  _FakeSocket(super.dao, super.api, super.tokenStore);

  int connects = 0;
  int disconnects = 0;

  @override
  Future<void> connect() async {
    connects += 1;
  }

  @override
  Future<void> disconnect() async {
    disconnects += 1;
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
  late _FakeSocket socket;
  late _FakeE2ee e2ee;
  late _FakePush push;
  late ProviderContainer container;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    final dao = ChatDao(database);
    final store = TokenStore();
    final api = ApiClient(store);
    socket = _FakeSocket(dao, api, store);
    e2ee = _FakeE2ee(store, api);
    push = _FakePush(api);

    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
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
}
