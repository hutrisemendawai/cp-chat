import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/features/conversations/conversations_screen.dart';

LocalConversation conversation({
  String id = 'direct',
  String type = 'direct',
  String? name,
  String? preview,
  int lastSeq = 0,
}) => LocalConversation(
  id: id,
  type: type,
  name: name,
  peerName: type == 'direct' ? 'Alice' : null,
  lastMessagePreview: preview,
  lastSeq: lastSeq,
  lastReadSeq: 0,
  unreadCount: 0,
  updatedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  late AppDatabase database;
  late StreamController<List<LocalConversation>> conversations;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    conversations = StreamController<List<LocalConversation>>.broadcast();
  });

  tearDown(() async {
    await conversations.close();
    await database.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          currentUserProvider.overrideWithValue(
            const User(id: 'me', name: 'Me'),
          ),
          conversationsProvider.overrideWith((ref) => conversations.stream),
        ],
        child: const MaterialApp(home: ConversationsScreen()),
      ),
    );
  }

  Future<void> showConversations(
    WidgetTester tester,
    List<LocalConversation> items,
  ) async {
    conversations.add(items);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'shows a pending first message preview before a sequence exists',
    (tester) async {
      await pumpApp(tester);
      await showConversations(tester, [conversation()]);
      expect(find.text('No messages yet'), findsOneWidget);

      await showConversations(tester, [
        conversation(preview: 'First outgoing message'),
      ]);
      expect(find.text('First outgoing message'), findsOneWidget);
      expect(find.text('No messages yet'), findsNothing);
    },
  );

  testWidgets('keeps a plaintext preview across conversation list rebuilds', (
    tester,
  ) async {
    await pumpApp(tester);
    await showConversations(tester, [
      conversation(preview: 'Decrypted message', lastSeq: 4),
    ]);
    expect(find.text('Decrypted message'), findsOneWidget);

    await showConversations(tester, [
      conversation(preview: 'Decrypted message', lastSeq: 4),
    ]);
    expect(find.text('Decrypted message'), findsOneWidget);
    expect(find.text('Encrypted message'), findsNothing);
    expect(find.text('No messages yet'), findsNothing);
  });

  testWidgets(
    'shows group previews and uses the fallback only for null previews',
    (tester) async {
      await pumpApp(tester);
      await showConversations(tester, [
        conversation(
          id: 'group',
          type: 'group',
          name: 'Team',
          preview: 'Group message',
        ),
        conversation(id: 'empty', preview: null, lastSeq: 3),
      ]);

      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Group message'), findsOneWidget);
      expect(find.text('No messages yet'), findsOneWidget);
    },
  );

  testWidgets('filters the list by chat type', (tester) async {
    await pumpApp(tester);
    await showConversations(tester, [
      conversation(id: 'group', type: 'group', name: 'Team', preview: 'Hi all'),
      conversation(id: 'direct', preview: 'Hey there'),
    ]);

    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.tap(find.text('Personal'));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('filters the list by the search query', (tester) async {
    await pumpApp(tester);
    await showConversations(tester, [
      conversation(id: 'a', preview: 'dinner plans'),
      conversation(
        id: 'b',
        type: 'group',
        name: 'Work',
        preview: 'standup notes',
      ),
    ]);

    await tester.enterText(find.byType(TextField), 'standup');
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No chats found'), findsOneWidget);
  });
}
