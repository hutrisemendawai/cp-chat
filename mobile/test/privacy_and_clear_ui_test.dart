import 'dart:io';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_registry.dart';
import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/chat/chat_screen.dart';
import 'package:cp_chat/features/chat/conversation_metadata.dart';
import 'package:cp_chat/features/conversations/conversations_screen.dart';
import 'package:cp_chat/features/profile/my_profile_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'support/factories.dart' as f;

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);
}

class _FakeApi extends ApiClient {
  _FakeApi(super.store);

  final User profile = const User(id: 'alice', name: 'Alice');
  int logouts = 0;
  int clearAllCalls = 0;
  final List<String> clearedConversations = [];

  @override
  Future<User> me() async => profile;

  @override
  Future<void> logout() async {
    logouts += 1;
  }

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async => const [];

  @override
  Future<Conversation> conversation(String id) async =>
      f.conversation(id, selfId: 'alice', peerId: 'peer', peerName: 'Peer');

  @override
  Future<int> clearConversation(String conversationId) async {
    clearedConversations.add(conversationId);
    return 5;
  }

  @override
  Future<Map<String, int>> clearAllHistory() async {
    clearAllCalls += 1;
    return {'c1': 5};
  }

  @override
  Future<int> publishKeys(PublicKeyBundle bundle, {bool historyWatermark = true}) async =>
      bundle.prekeys.length;

  @override
  Future<Presence> presence(String userId) async =>
      Presence(userId: userId, online: true);
}

class _FakeSocket extends ChatSocket {
  _FakeSocket(super.dao, super.api, super.tokenStore);

  @override
  Future<void> syncAll({String? selfId}) async {}

  @override
  Future<void> acknowledgeRead(String conversationId, int seq) async {}
}

class _SpyAuth extends AuthController {
  _SpyAuth(AuthState initial) : super(initial: initial);

  bool? lastWipeDeviceData;
  int logoutCalls = 0;

  @override
  Future<void> logout({bool wipeDeviceData = false}) async {
    logoutCalls += 1;
    lastWipeDeviceData = wipeDeviceData;
    state = const AuthState.unauthenticated();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDirs dirs;
  late _MapTokenStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cpchat_ui_');
    dirs = AppDirs.forTesting(root);
    await dirs.initialize();
    store = _MapTokenStore();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> flushRealIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pumpAndSettle();
  }

  AuthState aliceAuth() => AuthState.authenticated(
        const AuthSession(
          user: User(id: 'alice', name: 'Alice'),
          accessToken: 'acc',
          refreshToken: 'ref',
          expiresIn: 900,
        ),
      );

  group('Phase 5 UX dialogs & views', () {
    testWidgets('logout dialog defaults to retain and checking L2 shows E2EE warning and passes wipeDeviceData=true',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _FakeApi(store);
      final spyAuth = _SpyAuth(aliceAuth());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDirsProvider.overrideWithValue(dirs),
            tokenStoreProvider.overrideWithValue(store),
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(api),
            mediaCacheProvider.overrideWithValue(null),
            activeAccountUserIdProvider.overrideWith(
              () => ActiveAccountUserIdNotifier(initial: 'alice'),
            ),
            authControllerProvider.overrideWith(() => spyAuth),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: '/profile',
              routes: [
                GoRoute(path: '/profile', builder: (_, _) => const MyProfileScreen()),
                GoRoute(path: '/auth', builder: (_, _) => const Scaffold(body: Text('auth'))),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Sign out'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      // Checkbox unchecked by default; no E2EE wipe warning shown yet.
      expect(find.text('Also remove my data from this device'), findsOneWidget);
      expect(find.textContaining('Encrypted history is not restored'), findsNothing);

      // Check the L2 option -> E2EE warning appears and button updates.
      await tester.tap(find.text('Also remove my data from this device'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Encrypted history is not restored'), findsOneWidget);
      expect(find.text('Sign out & remove data'), findsOneWidget);

      await tester.tap(find.text('Sign out & remove data'));
      await tester.pumpAndSettle();

      expect(spyAuth.logoutCalls, 1);
      expect(spyAuth.lastWipeDeviceData, isTrue);
    });

    testWidgets('Privacy -> Clear all chats clears local rows and calls API', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(store);
      await dao.upsertConversation(f.conversation('c1', selfId: 'alice', lastSeq: 1), selfId: 'alice');
      await dao.upsertServerMessage(f.message('m1', conversationId: 'c1', seq: 1, content: 'hi'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDirsProvider.overrideWithValue(dirs),
            tokenStoreProvider.overrideWithValue(store),
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(api),
            mediaCacheProvider.overrideWithValue(null),
            activeAccountUserIdProvider.overrideWith(
              () => ActiveAccountUserIdNotifier(initial: 'alice'),
            ),
            authControllerProvider.overrideWith(() => AuthController(initial: aliceAuth())),
          ],
          child: const MaterialApp(home: MyProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Clear all chats'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear all chats'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Clear all chats'));
      await flushRealIo(tester);

      expect(api.clearAllCalls, 1);
      final remaining = await tester.runAsync(
        () => (db.select(db.localMessages)
              ..where((t) => t.conversationId.equals('c1')))
            .get(),
      );
      expect(remaining, isEmpty);
    });

    testWidgets('ChatScreen collapses consecutive undecryptable messages into one system row and shows key mismatch banner',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(store);
      final e2ee = E2eeManager(tokenStore: store, api: api);
      e2ee.keyMismatch.value = true;

      final conv = f.conversation('c1', selfId: 'alice', peerId: 'peer', peerName: 'Peer', lastSeq: 4);
      final cachedConv = LocalConversation(
        id: 'c1',
        type: 'direct',
        name: 'Peer',
        peerId: 'peer',
        lastSeq: 4,
        lastReadSeq: 0,
        clearedSeq: 0,
        unreadCount: 0,
        updatedAt: DateTime.utc(2026, 11, 26),
      );
      final localMsgs = [
        LocalMessage(
          clientMsgId: 'u1',
          conversationId: 'c1',
          seq: 1,
          senderId: 'peer',
          type: 'text',
          content: undecryptableContent,
          createdAt: DateTime.utc(2026, 11, 26, 10, 0, 1),
          status: 'sent',
        ),
        LocalMessage(
          clientMsgId: 'u2',
          conversationId: 'c1',
          seq: 2,
          senderId: 'peer',
          type: 'text',
          content: undecryptableContent,
          createdAt: DateTime.utc(2026, 11, 26, 10, 0, 2),
          status: 'sent',
        ),
        LocalMessage(
          clientMsgId: 'u3',
          conversationId: 'c1',
          seq: 3,
          senderId: 'peer',
          type: 'text',
          content: undecryptableContent,
          createdAt: DateTime.utc(2026, 11, 26, 10, 0, 3),
          status: 'sent',
        ),
        LocalMessage(
          clientMsgId: 'ok4',
          conversationId: 'c1',
          seq: 4,
          senderId: 'peer',
          type: 'text',
          content: 'after reset',
          createdAt: DateTime.utc(2026, 11, 26, 10, 0, 4),
          status: 'sent',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDirsProvider.overrideWithValue(dirs),
            tokenStoreProvider.overrideWithValue(store),
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(api),
            chatSocketProvider.overrideWithValue(_FakeSocket(dao, api, store)),
            e2eeManagerProvider.overrideWithValue(e2ee),
            mediaCacheProvider.overrideWithValue(null),
            conversationLocalProvider.overrideWith(
              (ref, id) => Stream.value(cachedConv),
            ),
            messagesProvider.overrideWith(
              (ref, id) => Stream.value(localMsgs),
            ),
            conversationMetadataProvider.overrideWith(
              (ref, id) => Future.value(conv),
            ),
            activeAccountUserIdProvider.overrideWith(
              () => ActiveAccountUserIdNotifier(initial: 'alice'),
            ),
            authControllerProvider.overrideWith(() => AuthController(initial: aliceAuth())),
          ],
          child: const MaterialApp(home: ChatScreen(conversationId: 'c1')),
        ),
      );
      await tester.pumpAndSettle();

      // 3 consecutive undecryptable rows collapse into ONE system notice.
      expect(find.text('Secure session reset – ask them to resend'), findsOneWidget);
      expect(find.text(undecryptableContent), findsNothing);
      expect(find.text('after reset'), findsOneWidget);

      // Key mismatch banner is shown with reset action.
      expect(find.textContaining('Encryption keys changed'), findsOneWidget);
      expect(find.text('Reset encryption'), findsOneWidget);
    });

    testWidgets('ConversationsScreen shows D1 fresh-partition prompt with Start fresh preselected',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(store);
      final container = ProviderContainer(
        overrides: [
          appDirsProvider.overrideWithValue(dirs),
          tokenStoreProvider.overrideWithValue(store),
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(api),
          chatSocketProvider.overrideWithValue(_FakeSocket(dao, api, store)),
          mediaCacheProvider.overrideWithValue(null),
          activeAccountUserIdProvider.overrideWith(
            () => ActiveAccountUserIdNotifier(initial: 'alice'),
          ),
          authControllerProvider.overrideWith(() => AuthController(initial: aliceAuth())),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConversationsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the one-time D1 prompt.
      container.read(freshPartitionPromptProvider.notifier).show();
      await tester.pumpAndSettle();

      expect(find.text('Start fresh on this device?'), findsOneWidget);
      expect(find.text('Start fresh'), findsOneWidget);
      expect(find.text('Keep group history'), findsOneWidget);

      // "Start fresh" is preselected -> tapping Continue calls clearAllHistory.
      await tester.tap(find.text('Continue'));
      await flushRealIo(tester);

      expect(api.clearAllCalls, 1);
      expect(container.read(freshPartitionPromptProvider), isFalse);
    });

    testWidgets('Accounts on this device sheet removes an inactive account partition',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final api = _FakeApi(store);
      final registry = AccountRegistry(store);
      await registry.register('alice', displayName: 'Alice');
      await registry.register('bob', displayName: 'Bob');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDirsProvider.overrideWithValue(dirs),
            tokenStoreProvider.overrideWithValue(store),
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(api),
            mediaCacheProvider.overrideWithValue(null),
            activeAccountUserIdProvider.overrideWith(
              () => ActiveAccountUserIdNotifier(initial: 'alice'),
            ),
            authControllerProvider.overrideWith(() => AuthController(initial: aliceAuth())),
          ],
          child: const MaterialApp(home: MyProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Accounts on this device'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accounts on this device'));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsWidgets);
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await flushRealIo(tester);

      expect(await registry.findByAccountId(accountIdForUser('bob')), isNull);
      expect(await registry.findByAccountId(accountIdForUser('alice')), isNotNull);
    });
  });
}
