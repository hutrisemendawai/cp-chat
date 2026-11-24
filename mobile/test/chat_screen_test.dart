import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/chat/chat_screen.dart';
import 'package:cp_chat/features/chat/conversation_metadata.dart';

/// A socket that never touches the network, so the screen's open-time sync and
/// read ack resolve instantly in a widget test.
class _StubChatSocket extends ChatSocket {
  _StubChatSocket(ChatDao dao) : super(dao, ApiClient(TokenStore()), TokenStore());

  @override
  Future<void> syncAll({String? selfId}) async {}

  @override
  Future<void> acknowledgeRead(String conversationId, int seq) async {}
}

const _selfId = 'me';

Conversation _groupConversation({String name = 'Weekend Squad'}) => Conversation(
  id: 'g1',
  type: 'group',
  name: name,
  members: const [
    ConversationMember(user: User(id: _selfId, name: 'Me'), role: 'admin', lastReadSeq: 0),
    ConversationMember(user: User(id: 'u2', name: 'Bob'), role: 'member', lastReadSeq: 0),
    ConversationMember(user: User(id: 'u3', name: 'Carol'), role: 'member', lastReadSeq: 0),
  ],
  lastSeq: 0,
  lastReadSeq: 0,
  unreadCount: 0,
  createdAt: DateTime.utc(2026, 1, 1),
);

LocalConversation _cachedGroup({String name = 'Weekend Squad'}) => LocalConversation(
  id: 'g1',
  type: 'group',
  name: name,
  lastSeq: 0,
  lastReadSeq: 0,
  unreadCount: 0,
  updatedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    RouterConfig<Object>? router,
    Conversation? metadata,
    bool offline = false,
    LocalConversation? cached,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          currentUserProvider.overrideWithValue(const User(id: _selfId, name: 'Me')),
          chatSocketProvider.overrideWithValue(_StubChatSocket(ChatDao(database))),
          conversationLocalProvider.overrideWith(
            (ref, conversationId) => Stream.value(cached ?? _cachedGroup()),
          ),
          messagesProvider.overrideWith(
            (ref, conversationId) => Stream.value(const <LocalMessage>[]),
          ),
          conversationMetadataProvider.overrideWith(
            (ref, conversationId) =>
                Future.value(offline ? null : (metadata ?? _groupConversation())),
          ),
        ],
        child: router == null
            ? const MaterialApp(home: ChatScreen(conversationId: 'g1'))
            : MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('group header shows the group name, never a member name', (tester) async {
    await pumpChat(tester, metadata: _groupConversation(name: 'Weekend Squad'));

    expect(find.text('Weekend Squad'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Carol'), findsNothing);
    expect(find.text('Me'), findsNothing);
  });

  testWidgets('group header shows the member count subtitle', (tester) async {
    await pumpChat(tester, metadata: _groupConversation());

    expect(find.text('3 members'), findsOneWidget);
  });

  testWidgets('group header falls back to the cached name when offline', (tester) async {
    await pumpChat(tester, offline: true, cached: _cachedGroup(name: 'Offline Crew'));

    expect(find.text('Offline Crew'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Carol'), findsNothing);
  });

  testWidgets('tapping the group header opens group info', (tester) async {
    final router = GoRouter(
      initialLocation: '/conversations/g1',
      routes: [
        GoRoute(
          path: '/conversations/:id',
          builder: (context, state) =>
              ChatScreen(conversationId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/conversations/:id/info',
          builder: (context, state) => const Scaffold(body: Text('Group info screen')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await pumpChat(tester, router: router, metadata: _groupConversation());

    await tester.tap(find.text('Weekend Squad'));
    await tester.pumpAndSettle();

    expect(find.text('Group info screen'), findsOneWidget);
  });
}
