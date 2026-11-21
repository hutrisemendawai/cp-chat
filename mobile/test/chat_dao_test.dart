import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';

import 'support/factories.dart';

void main() {
  late AppDatabase database;
  late ChatDao dao;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('outbox', () {
    test('an optimistic send is pending, queued, and visible immediately', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'hello',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      final pending = await dao.pendingOutbox();
      expect(pending, hasLength(1));
      expect(pending.single.clientMsgId, 'c1');
      expect(pending.single.attempts, 0);

      final messages = await dao.watchMessages('conv-1').first;
      expect(messages, hasLength(1));
      expect(messages.single.status, 'pending');
      expect(messages.single.seq, isNull);
    });

    test('a server echo reconciles the optimistic row and clears the outbox', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'hello',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await dao.upsertServerMessage(
        message('c1', conversationId: 'conv-1', seq: 1, senderId: 'me', content: 'hello'),
      );

      final messages = await dao.watchMessages('conv-1').first;
      expect(messages, hasLength(1), reason: 'the echo must not duplicate the bubble');
      expect(messages.single.seq, 1);
      expect(messages.single.id, 'server-c1');
      expect(messages.single.status, 'sent');
      expect(await dao.pendingOutbox(), isEmpty);
    });

    test('recording an attempt increments the retry counter', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'retry me',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await dao.recordAttempt('c1');
      await dao.recordAttempt('c1');

      final pending = await dao.pendingOutbox();
      expect(pending.single.attempts, 2);
      expect(pending.single.lastAttemptAt, isNotNull);
    });

    test('deleting a failed message removes it from the outbox too', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'gone',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await dao.markFailed('c1');

      await dao.deleteMessage('c1');

      expect(await dao.watchMessages('conv-1').first, isEmpty);
      expect(await dao.pendingOutbox(), isEmpty);
    });
  });

  group('status transitions', () {
    test('never moves a message backwards', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'hi',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await dao.applyStatus('c1', 'sent');
      await dao.applyStatus('c1', 'delivered');
      await dao.applyStatus('c1', 'read');
      // A late, out-of-order frame must not regress the tick state.
      await dao.applyStatus('c1', 'sent');

      final messages = await dao.watchMessages('conv-1').first;
      expect(messages.single.status, 'read');
    });

    test('ignores a status for an unknown message', () async {
      await dao.applyStatus('does-not-exist', 'read');
      expect(await dao.watchMessages('conv-1').first, isEmpty);
    });
  });

  group('cursor and unread bookkeeping', () {
    test('tracks the highest local seq', () async {
      expect(await dao.localMaxSeq('conv-1'), 0);

      await dao.upsertServerMessage(message('a', conversationId: 'conv-1', seq: 3));
      await dao.upsertServerMessage(message('b', conversationId: 'conv-1', seq: 7));

      expect(await dao.localMaxSeq('conv-1'), 7);
    });

    test('read cursor only moves forward', () async {
      await dao.upsertConversations([conversation('conv-1', selfId: 'me')]);
      await dao.setReadCursor('conv-1', 5);
      await dao.setReadCursor('conv-1', 2);

      final row = await dao.conversation('conv-1');
      expect(row!.lastReadSeq, 5);
    });

    test('clearing unread resets the badge', () async {
      await dao.upsertConversations([
        conversation('conv-1', selfId: 'me', unreadCount: 4),
      ]);
      await dao.clearUnread('conv-1');

      final row = await dao.conversation('conv-1');
      expect(row!.unreadCount, 0);
    });
  });

  group('conversation cache', () {
    test('caches the direct peer name and message preview', () async {
      await dao.upsertConversations(
        [
          conversation(
            'conv-1',
            selfId: 'me',
            peerName: 'Bob',
            lastSeq: 4,
            lastMessage: message('a', conversationId: 'conv-1', seq: 4, content: 'latest'),
          ),
        ],
        selfId: 'me',
      );

      final row = await dao.conversation('conv-1');
      expect(row!.peerName, 'Bob');
      expect(row.lastMessagePreview, 'latest');
      expect(row.lastSeq, 4);
    });

    test('a synced message updates the preview and ordering timestamp', () async {
      await dao.upsertConversations([conversation('conv-1', selfId: 'me')]);

      await dao.upsertServerMessage(
        message(
          'a',
          conversationId: 'conv-1',
          seq: 2,
          content: 'newest',
          createdAt: DateTime.utc(2026, 2, 1),
        ),
      );

      final row = await dao.conversation('conv-1');
      expect(row!.lastMessagePreview, 'newest');
      expect(row.lastSeq, 2);
      // Drift persists DateTimes as epoch seconds and reads them back as local
      // time, so compare the instant rather than the UTC flag.
      expect(row.updatedAt.millisecondsSinceEpoch, DateTime.utc(2026, 2, 1).millisecondsSinceEpoch);
    });

    test('does not regress a newer local cursor with a stale server row', () async {
      await dao.upsertConversations([conversation('conv-1', selfId: 'me', lastSeq: 10)]);
      await dao.upsertConversation(
        conversation('conv-1', selfId: 'me', lastSeq: 4),
        selfId: 'me',
      );

      final row = await dao.conversation('conv-1');
      expect(row!.lastSeq, 10);
    });

    test('clearAll wipes local state on logout', () async {
      await dao.upsertConversations([conversation('conv-1', selfId: 'me')]);
      await dao.upsertServerMessage(message('a', conversationId: 'conv-1', seq: 1));

      await dao.clearAll();

      expect(await dao.conversations(), isEmpty);
      expect(await dao.watchMessages('conv-1').first, isEmpty);
      expect(await dao.pendingOutbox(), isEmpty);
    });

    test('keeps display content separate from the encrypted wire body', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c-e2ee',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'the secret plan',
        wireContent: 'e2ee:v1:{"ct":"ciphertext"}',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      // The bubble renders the plaintext the user typed...
      final messages = await dao.watchMessages('conv-1').first;
      expect(messages.single.content, 'the secret plan');

      // ...while a retry resends the exact ciphertext, never a re-encryption.
      final pending = await dao.pendingOutbox();
      expect(pending.single.content, 'the secret plan');
      expect(pending.single.wireContent, 'e2ee:v1:{"ct":"ciphertext"}');
    });

    test('wire content is null for an unencrypted send', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c-plain',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'plain',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      final pending = await dao.pendingOutbox();
      expect(pending.single.wireContent, isNull);
    });
  });
}
