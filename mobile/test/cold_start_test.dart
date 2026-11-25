import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/notifications/local_notification_service.dart';
import 'package:cp_chat/core/notifications/push_registration.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/auth/auth_screen.dart';
import 'package:cp_chat/features/conversations/conversations_screen.dart';
import 'package:cp_chat/features/home/home_shell.dart';
import 'package:cp_chat/features/splash/splash_screen.dart';
import 'package:cp_chat/main.dart';

/// Token store backed by memory so a cold start can be seeded without the
/// platform keychain.
class _MemoryTokenStore extends TokenStore {
  _MemoryTokenStore({this.access, this.refresh, this.userId, this.user});

  String? access;
  String? refresh;
  String? userId;
  User? user;

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<String?> readUserId() async => userId;

  @override
  Future<User?> readUser() async => user;

  @override
  Future<void> saveUser(User value) async => user = value;

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    userId = null;
    user = null;
  }
}

/// Answers the background session-validation call without a network. [onMe]
/// decides the outcome: a user, an offline failure, or a revoked (401) session.
class _FakeApi extends ApiClient {
  _FakeApi(super.store);

  Future<User> Function()? onMe;
  int logouts = 0;

  @override
  Future<User> me() => onMe?.call() ?? Future.value(const User(id: 'me', name: 'Me'));

  @override
  Future<void> logout() async {
    logouts += 1;
  }

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async => const [];

  @override
  Future<List<User>> friends() async => const [];
}

/// Records connect/disconnect instead of opening a real socket.
class _FakeSocket extends ChatSocket {
  _FakeSocket(super.dao, super.api, super.tokenStore);

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}
}

class _FakeE2ee extends E2eeManager {
  _FakeE2ee(TokenStore store, ApiClient api) : super(tokenStore: store, api: api);

  @override
  Future<void> bootstrap() async {}

  @override
  void reset() {}
}

class _FakePush extends PushRegistration {
  _FakePush(super.api);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// No-op notification tray so the plugin is never touched in a widget test.
class _FakeNotifications extends LocalNotificationService {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> dispose() async {}

  @override
  String? get coldStartConversationId => null;
}

/// A session that never resolves, to exercise the splash fallback.
class _InitializingAuth extends AuthController {
  @override
  AuthState build() => const AuthState.initializing();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Boots the real app widget with the same session seeding `main()` performs,
  /// plus fake collaborators so nothing touches the network or platform plugins.
  ///
  /// The container is owned here (not by a `ProviderScope`) so it can be disposed
  /// before the Drift database is closed; otherwise the still-open chat-list
  /// stream keeps the test isolate alive.
  Future<void> pumpColdStart(
    WidgetTester tester, {
    required _MemoryTokenStore store,
    required AuthState initial,
    required _FakeApi api,
  }) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final dao = ChatDao(database);
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        authControllerProvider.overrideWith(() => AuthController(initial: initial)),
        apiClientProvider.overrideWithValue(api),
        appDatabaseProvider.overrideWithValue(database),
        chatSocketProvider.overrideWithValue(_FakeSocket(dao, api, store)),
        e2eeManagerProvider.overrideWithValue(_FakeE2ee(store, api)),
        pushRegistrationProvider.overrideWithValue(_FakePush(api)),
        localNotificationServiceProvider.overrideWithValue(_FakeNotifications()),
        bootstrapProvider.overrideWith((ref) async {}),
      ],
    );
    // LIFO teardown: dispose the container first so its stream subscriptions are
    // cancelled, then close the database.
    addTearDown(database.close);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const CpChatApp()),
    );
  }

  testWidgets(
    'cold start with a persisted session opens the chat list on the first frame',
    (tester) async {
      final store = _MemoryTokenStore(
        access: 'access',
        refresh: 'refresh',
        userId: 'me',
        user: const User(id: 'me', name: 'Me'),
      );
      final initial = await hydrateAuthState(store);
      expect(initial.isAuthenticated, isTrue);

      await pumpColdStart(
        tester,
        store: store,
        initial: initial,
        api: _FakeApi(store),
      );

      // The very first frame is already the shell: no login screen, no splash.
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(find.byType(SplashScreen), findsNothing);

      // And it stays there across later frames.
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cold start with no persisted session shows the sign-in screen',
      (tester) async {
    final store = _MemoryTokenStore();
    final initial = await hydrateAuthState(store);
    expect(initial.isUnauthenticated, isTrue);

    await pumpColdStart(
      tester,
      store: store,
      initial: initial,
      api: _FakeApi(store),
    );

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an offline cold start keeps the user on the chat list',
      (tester) async {
    final store = _MemoryTokenStore(
      access: 'access',
      refresh: 'refresh',
      userId: 'me',
      user: const User(id: 'me', name: 'Me'),
    );
    final initial = await hydrateAuthState(store);

    final api = _FakeApi(store)
      ..onMe = () async => throw DioException(
            requestOptions: RequestOptions(path: '/api/v1/users/me'),
            type: DioExceptionType.connectionError,
            message: 'offline',
          );

    await pumpColdStart(tester, store: store, initial: initial, api: api);
    await tester.pumpAndSettle();

    // A transient failure must not sign the user out.
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
    expect(api.logouts, 0);
    expect(store.access, 'access');
    expect(store.refresh, 'refresh');
  });

  testWidgets('a revoked session is signed out back to the sign-in screen',
      (tester) async {
    final store = _MemoryTokenStore(
      access: 'access',
      refresh: 'refresh',
      userId: 'me',
      user: const User(id: 'me', name: 'Me'),
    );
    final initial = await hydrateAuthState(store);

    final api = _FakeApi(store)
      ..onMe = () async => throw ApiException(
            'unauthorized',
            'Unauthorized',
            statusCode: 401,
          );

    await pumpColdStart(tester, store: store, initial: initial, api: api);

    // The shell shows first (optimistic entry)...
    expect(find.byType(HomeShell), findsOneWidget);

    // ...then the definitive auth failure transitions cleanly to /auth.
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(store.access, isNull);
    expect(store.refresh, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unresolved session shows the splash, never the login screen',
      (tester) async {
    final container = ProviderContainer(
      overrides: [authControllerProvider.overrideWith(_InitializingAuth.new)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            routerConfig: ref.watch(routerProvider),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });
}
