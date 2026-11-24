import 'dart:async';

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
import 'package:cp_chat/features/chat/chat_controller.dart';
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

/// A controller that records sends without touching the socket, so the composer
/// can be driven deterministically without E2EE or a live connection.
class _FakeChatController extends ChatController {
  _FakeChatController(super.ref, super.conversationId);

  final List<String> sent = [];

  @override
  Future<void> sendText(String text) async => sent.add(text);

  @override
  Future<void> markRead() async {}
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

LocalMessage _message(int seq, {String senderId = 'u2'}) => LocalMessage(
  clientMsgId: 'c$seq',
  conversationId: 'g1',
  seq: seq,
  senderId: senderId,
  type: 'text',
  content: 'message $seq',
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: seq)),
  status: 'sent',
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
    List<LocalMessage> messages = const <LocalMessage>[],
    Stream<List<LocalMessage>>? messageStream,
    ChatController Function(Ref ref, String conversationId)? chatController,
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
            (ref, conversationId) => messageStream ?? Stream.value(messages),
          ),
          conversationMetadataProvider.overrideWith(
            (ref, conversationId) =>
                Future.value(offline ? null : (metadata ?? _groupConversation())),
          ),
          if (chatController != null)
            chatControllerProvider.overrideWith(
              (ref, conversationId) => chatController(ref, conversationId),
            ),
        ],
        child: router == null
            ? const MaterialApp(home: ChatScreen(conversationId: 'g1'))
            : MaterialApp.router(routerConfig: router),
      ),
    );
    // A live stream has not emitted yet, so the feed is still loading (and its
    // spinner never settles); the caller drives the frames after adding data.
    if (messageStream == null) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  // The chat feed is a reversed ListView; this helper resolves its scroll state
  // without clashing with the composer's own editable scrollable.
  ScrollableState feed(WidgetTester tester) => tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );

  void showKeyboard(WidgetTester tester, {double bottom = 300}) {
    tester.view.viewInsets = FakeViewPadding(bottom: bottom);
    addTearDown(tester.view.reset);
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

  testWidgets('newest message is anchored above the composer', (tester) async {
    await pumpChat(tester, messages: [_message(1), _message(2), _message(3)]);

    final oldest = tester.getRect(find.text('message 1'));
    final middle = tester.getRect(find.text('message 2'));
    final newest = tester.getRect(find.text('message 3'));
    final composer = tester.getRect(find.byType(TextField));

    expect(oldest.top, lessThan(middle.top));
    expect(middle.top, lessThan(newest.top));
    expect(newest.bottom, lessThanOrEqualTo(composer.top));
  });

  testWidgets('opening the keyboard keeps the newest message above the composer', (tester) async {
    await pumpChat(tester, messages: [_message(1), _message(2), _message(3)]);

    showKeyboard(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final newest = tester.getRect(find.text('message 3'));
    final composer = tester.getRect(find.byType(TextField));
    expect(newest.bottom, lessThanOrEqualTo(composer.top));
  });

  testWidgets('sending a message scrolls the feed to the newest bubble', (tester) async {
    await pumpChat(
      tester,
      messages: [for (var seq = 1; seq <= 40; seq++) _message(seq)],
      chatController: (ref, conversationId) => _FakeChatController(ref, conversationId),
    );

    final position = feed(tester).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(position.pixels, greaterThan(0));

    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(feed(tester).position.pixels, 0);
  });

  testWidgets('an incoming message does not yank a user reading history', (tester) async {
    final stream = StreamController<List<LocalMessage>>.broadcast();
    addTearDown(stream.close);

    await pumpChat(tester, messageStream: stream.stream);
    stream.add([for (var seq = 1; seq <= 40; seq++) _message(seq)]);
    await tester.pumpAndSettle();

    final position = feed(tester).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final scrolledAway = position.pixels;
    expect(scrolledAway, greaterThan(0));

    stream.add([for (var seq = 1; seq <= 41; seq++) _message(seq)]);
    await tester.pumpAndSettle();

    // Still well away from the live edge instead of being yanked to the bottom.
    expect(feed(tester).position.pixels, greaterThan(80));
  });
}
