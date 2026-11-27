import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/crypto/e2ee_service.dart' show undecryptableContent;
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

    test('a sent status persists seq and clears the outbox', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'hello',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      expect(await dao.pendingOutbox(), hasLength(1));

      await dao.applyStatus('c1', 'sent', seq: 7);

      final row = (await dao.watchMessages('conv-1').first).single;
      expect(row.status, 'sent');
      expect(row.seq, 7);
      expect(await dao.pendingOutbox(), isEmpty);
    });

    test('a server status recovers a message that timed out as failed', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'slow',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await dao.markFailed('c1');
      expect((await dao.watchMessages('conv-1').first).single.status, 'failed');

      // The send did land after all; the late ack must clear the failure.
      await dao.applyStatus('c1', 'sent', seq: 3);

      final row = (await dao.watchMessages('conv-1').first).single;
      expect(row.status, 'sent');
      expect(row.seq, 3);
      expect(await dao.pendingOutbox(), isEmpty);
    });

    test('a manual retry returns a failed message to pending', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c1',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'again',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      await dao.markFailed('c1');

      await dao.markPending('c1');

      expect((await dao.watchMessages('conv-1').first).single.status, 'pending');
      expect(await dao.pendingOutbox(), hasLength(1));
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

    test('caches the peer id, nickname and avatar for the chat list', () async {
      await dao.upsertConversations(
        [
          conversation(
            'conv-1',
            selfId: 'me',
            peerId: 'bob',
            peerName: 'Bob',
            peerNickname: 'bo',
            peerAvatarKey: 'bob/avatar.jpg',
          ),
        ],
        selfId: 'me',
      );

      final row = await dao.conversation('conv-1');
      expect(row!.peerId, 'bob');
      expect(row.peerNickname, 'bo');
      expect(row.peerAvatarUrl, 'bob/avatar.jpg');
    });

    test('a group caches no peer identity', () async {
      await dao.upsertConversations(
        [
          conversation('group-1', selfId: 'me', type: 'group', name: 'Team'),
        ],
        selfId: 'me',
      );

      final row = await dao.conversation('group-1');
      expect(row!.peerName, isNull);
      expect(row.peerId, isNull);
      expect(row.peerNickname, isNull);
      expect(row.peerAvatarUrl, isNull);
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

    test('a synced ciphertext does not replace the decrypted bubble', () async {
      await dao.enqueueOutgoing(
        clientMsgId: 'c-e2ee',
        conversationId: 'conv-1',
        senderId: 'me',
        type: 'text',
        content: 'the secret plan',
        wireContent: 'e2ee:v1:{"ik":"a","ct":"b","n":"c","m":"d"}',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      // The server syncs the same message back with its ciphertext body.
      await dao.upsertServerMessage(
        message(
          'c-e2ee',
          conversationId: 'conv-1',
          seq: 1,
          senderId: 'me',
          content: 'e2ee:v1:{"ik":"a","ct":"b","n":"c","m":"d"}',
        ),
      );

      final row = (await dao.watchMessages('conv-1').first).single;
      expect(row.content, 'the secret plan');
      expect(row.seq, 1);
      expect(row.status, 'sent');
    });

    test('a ciphertext preview never leaks the envelope', () async {
      await dao.upsertConversations(
        [
          conversation(
            'conv-1',
            selfId: 'me',
            lastSeq: 1,
            lastMessage: message(
              'a',
              conversationId: 'conv-1',
              seq: 1,
              content: 'e2ee:v1:{"ik":"a","ct":"b","n":"c","m":"d"}',
            ),
          ),
        ],
        selfId: 'me',
      );

      final row = await dao.conversation('conv-1');
      expect(row!.lastMessagePreview, 'Encrypted message');
    });

    test('re-fetching an unreadable body keeps the decrypted bubble', () async {
      await dao.upsertServerMessage(
        message('a', conversationId: 'conv-1', seq: 1, content: 'readable'),
      );

      // The same message comes back from history as the placeholder (the
      // ratchet already moved past it), which must not replace the text.
      await dao.upsertServerMessage(
        message('a', conversationId: 'conv-1', seq: 1, content: undecryptableContent),
      );

      final row = (await dao.watchMessages('conv-1').first).single;
      expect(row.content, 'readable');
    });

    test('a successful late decrypt replaces an earlier placeholder', () async {
      // The reverse order: a sync stored the placeholder because the session was
      // not ready, and the next attempt decrypted successfully. The plaintext
      // must win, so the bubble recovers instead of staying broken.
      await dao.upsertServerMessage(
        message('a', conversationId: 'conv-1', seq: 1, content: undecryptableContent),
      );

      await dao.upsertServerMessage(
        message('a', conversationId: 'conv-1', seq: 1, content: 'recovered'),
      );

      final row = (await dao.watchMessages('conv-1').first).single;
      expect(row.content, 'recovered');
    });

    test('looks up a stored message by client id', () async {
      expect(await dao.message('missing'), isNull);

      await dao.upsertServerMessage(
        message('a', conversationId: 'conv-1', seq: 1, content: 'hello'),
      );

      final row = await dao.message('a');
      expect(row, isNotNull);
      expect(row!.content, 'hello');
    });
  });

  group('preview reconciliation', () {
    const cipher = 'e2ee:v1:{"ct":"secret"}';
    final t1 = DateTime.utc(2026, 2, 1);
    final t2 = DateTime.utc(2026, 2, 2);

    Future<void> enqueue(String id, String content, DateTime time) => dao.enqueueOutgoing(
          clientMsgId: id,
          conversationId: 'conv-1',
          senderId: 'me',
          type: 'text',
          content: content,
          wireContent: cipher,
          createdAt: time,
        );

    test('both upserts resolve plaintext and retain peer metadata', () async {
      await dao.upsertConversations([
        conversation('conv-1', selfId: 'me', peerName: 'Bob', peerNickname: 'b'),
      ], selfId: 'me');
      await dao.upsertServerMessage(message('a', seq: 3, content: 'readable'));
      final summary = conversation('conv-1', selfId: 'me', lastSeq: 3,
          lastMessage: message('a', seq: 3, content: cipher));
      await dao.upsertConversations([summary]);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'readable');
      await dao.upsertConversation(summary);
      final row = (await dao.conversation('conv-1'))!;
      expect(row.lastMessagePreview, 'readable');
      expect(row.peerName, 'Bob');
      expect(row.peerNickname, 'b');
    });

    test('sequence matching and cross-conversation identity are isolated', () async {
      await dao.upsertServerMessage(message('local', seq: 4, content: 'local text'));
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 4,
          lastMessage: message('server', seq: 4, content: cipher)));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'local text');
      await dao.upsertServerMessage(message('same-id', conversationId: 'other', seq: 5,
          content: 'other secret'));
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 5,
          lastMessage: message('same-id', seq: 5, content: cipher)));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'Encrypted message');
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 6,
          lastMessage: message('new', seq: 6, content: undecryptableContent)));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'Encrypted message');
    });

    test('equal summary preserves plaintext but newer ciphertext does not', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 2,
          lastMessage: message('a', seq: 2, content: 'known')));
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 2,
          lastMessage: message('a', seq: 2, content: cipher)));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'known');
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 3,
          lastMessage: message('b', seq: 3, content: cipher)));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'Encrypted message');
    });

    test('stale and empty summaries and explicit cursor reset', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 5,
          lastMessage: message('new', seq: 5, content: 'newest')));
      await dao.upsertConversations([conversation('conv-1', selfId: 'me', lastSeq: 2,
          lastMessage: message('old', seq: 2, content: 'old'))]);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'newest');
      expect((await dao.conversation('conv-1'))!.lastSeq, 5);
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 5));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, isNull);
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 1),
          preserveLocalCursor: false);
      expect((await dao.conversation('conv-1'))!.lastSeq, 1);
    });

    test('group text and attachments retain normal previews', () async {
      await dao.upsertConversation(conversation('group', selfId: 'me', type: 'group',
          lastSeq: 1, lastMessage: message('g', conversationId: 'group', content: 'team')));
      expect((await dao.conversation('group'))!.lastMessagePreview, 'team');
      await dao.upsertServerMessage(message('img', conversationId: 'group', seq: 2,
          type: 'image', content: cipher));
      expect((await dao.conversation('group'))!.lastMessagePreview, 'Sent an attachment');
    });

    test('pending previews survive refresh, history, echo, and ack', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await enqueue('first', 'first text', t1);
      final first = (await dao.conversation('conv-1'))!;
      expect(first.lastSeq, 0);
      expect(first.lastMessagePreview, 'first text');
      expect(first.updatedAt.millisecondsSinceEpoch, t1.millisecondsSinceEpoch);
      await enqueue('second', 'second text', t2);
      await dao.upsertConversations([conversation('conv-1', selfId: 'me')]);
      await dao.upsertServerMessage(message('old', seq: 1, content: 'history'));
      await dao.upsertServerMessage(message('first', seq: 2, senderId: 'me', content: cipher));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second text');
      await dao.applyStatus('first', 'read', seq: 2);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second text');
      await dao.applyStatus('second', 'sent', seq: 3);
      await dao.upsertServerMessage(message('second', seq: 3, senderId: 'me', content: cipher));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second text');
      expect(await dao.pendingOutbox(), isEmpty);
    });

    test('newer ack before older ack or echo keeps the newer preview', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await enqueue('first', 'first', t1);
      await enqueue('second', 'second', t2);
      await dao.applyStatus('second', 'sent', seq: 2);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second');
      await dao.upsertServerMessage(message('first', seq: 1, content: cipher));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second');
      await dao.applyStatus('first', 'read', seq: 1);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second');
    });

    test('unsequenced ack and equal timestamps keep newest pending', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await enqueue('first', 'first', t1);
      await enqueue('second', 'second', t1);
      await dao.applyStatus('first', 'sent');
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second');
      await dao.upsertServerMessage(message('first', seq: 1, content: cipher));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'second');
    });

    test('history and unreadable equality cannot regress preview', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 4,
          lastMessage: message('latest', seq: 4, content: 'latest')));
      await dao.upsertServerMessage(message('old', seq: 2, content: 'old', createdAt: t2));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'latest');
      await dao.upsertServerMessage(message('latest', seq: 4, content: undecryptableContent));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'latest');
      await dao.upsertServerMessage(message('latest', seq: 4, content: 'decrypted'));
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'decrypted');
    });

    test('deleting pending and retry preserve correct preview and wire body', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await dao.upsertServerMessage(message('server', seq: 1, content: 'server text'));
      await enqueue('first', 'first', t1);
      await enqueue('second', 'second', t2);
      await dao.deleteMessage('second');
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'first');
      await dao.markFailed('first');
      await dao.markPending('first');
      expect((await dao.pendingOutbox()).single.wireContent, cipher);
      await dao.deleteMessage('first');
      var current = (await dao.conversation('conv-1'))!;
      expect(current.lastMessagePreview, 'server text');
      expect(current.updatedAt.millisecondsSinceEpoch, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 1,
          lastMessage: message('server', seq: 1, content: 'server text')));
      current = (await dao.conversation('conv-1'))!;
      expect(current.updatedAt.millisecondsSinceEpoch, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    });

    test('conflicting server sequence rolls back message and outbox changes', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await dao.upsertServerMessage(message('existing', seq: 1, content: 'server'));
      await enqueue('pending', 'local', t1);
      await expectLater(
        dao.upsertServerMessage(message('pending', seq: 1, content: cipher)),
        throwsA(anything),
      );
      expect((await dao.message('pending'))!.seq, isNull);
      expect((await dao.pendingOutbox()).single.clientMsgId, 'pending');
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'local');
    });

    test('older ack restores newer server preview', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await dao.upsertServerMessage(message('new', seq: 10, content: 'newest'));
      await enqueue('old-pending', 'queued', t1);
      await dao.applyStatus('old-pending', 'sent', seq: 2);
      expect((await dao.conversation('conv-1'))!.lastMessagePreview, 'newest');
    });
  });

  group('first-contact provisional conversation', () {
    test('atomically creates the conversation row for an unknown chat', () async {
      await dao.upsertServerMessage(
        message(
          'm1',
          conversationId: 'new-chat',
          seq: 1,
          senderId: 'alice',
          content: 'hello from a stranger',
        ),
        ensureConversation: const ProvisionalConversationHint(
          peerId: 'alice',
          peerName: 'Alice',
          peerAvatarUrl: 'alice/avatar.jpg',
        ),
        incrementUnread: true,
      );

      final rows = await dao.watchConversations().first;
      expect(rows, hasLength(1), reason: 'the chat list must emit immediately');
      final row = rows.single;
      expect(row.id, 'new-chat');
      expect(row.type, 'direct');
      expect(row.peerId, 'alice');
      expect(row.peerName, 'Alice');
      expect(row.peerAvatarUrl, 'alice/avatar.jpg');
      expect(row.lastSeq, 1);
      expect(row.lastMessagePreview, 'hello from a stranger');
      expect(row.unreadCount, 1);

      // The message is not orphaned.
      expect((await dao.watchMessages('new-chat').first).single.content,
          'hello from a stranger');
    });

    test('a group hint caches the group name and no peer identity', () async {
      await dao.upsertServerMessage(
        message('g1', conversationId: 'group-1', seq: 1, senderId: 'alice', content: 'hi team'),
        ensureConversation: const ProvisionalConversationHint(
          type: 'group',
          conversationName: 'Weekend Squad',
          peerId: 'alice',
          peerName: 'Alice',
        ),
      );

      final row = (await dao.conversation('group-1'))!;
      expect(row.type, 'group');
      expect(row.name, 'Weekend Squad');
      expect(row.peerId, isNull);
      expect(row.peerName, isNull);
    });

    test('increments unread per new inbound message but never on replay', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me', lastSeq: 0));

      for (final seq in [1, 2, 3]) {
        await dao.upsertServerMessage(
          message('m$seq', seq: seq, senderId: 'them', content: 'hi $seq'),
          incrementUnread: true,
        );
      }
      expect((await dao.conversation('conv-1'))!.unreadCount, 3);

      // A sync replay of an already-stored row must not double-count.
      await dao.upsertServerMessage(
        message('m3', seq: 3, senderId: 'them', content: 'hi 3'),
        incrementUnread: true,
      );
      expect((await dao.conversation('conv-1'))!.unreadCount, 3);
    });

    test('a message at or below the read cursor does not bump unread', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await dao.setReadCursor('conv-1', 5);

      await dao.upsertServerMessage(
        message('m6', seq: 6, senderId: 'them', content: 'new'),
        incrementUnread: true,
      );
      expect((await dao.conversation('conv-1'))!.unreadCount, 1);

      await dao.upsertServerMessage(
        message('m2', seq: 2, senderId: 'them', content: 'old'),
        incrementUnread: true,
      );
      expect(
        (await dao.conversation('conv-1'))!.unreadCount,
        1,
        reason: 'a message below the read cursor was already read',
      );
    });

    test('a stale REST summary preserves live unread and preview', () async {
      await dao.upsertConversation(conversation('conv-1', selfId: 'me'));
      await dao.upsertServerMessage(
        message('m1', seq: 1, senderId: 'them', content: 'Hello 1'),
        incrementUnread: true,
      );
      await dao.upsertServerMessage(
        message('m2', seq: 2, senderId: 'them', content: 'Hello 2'),
        incrementUnread: true,
      );

      var row = (await dao.conversation('conv-1'))!;
      expect(row.lastSeq, 2);
      expect(row.unreadCount, 2);

      // The REST summary was captured at creation (seq 0, unread 0) but
      // resolves after the live frames were persisted.
      await dao.upsertConversation(
        conversation('conv-1', selfId: 'me', peerName: 'Alice', lastSeq: 0, unreadCount: 0),
        selfId: 'me',
      );

      row = (await dao.conversation('conv-1'))!;
      expect(row.peerName, 'Alice', reason: 'authoritative peer metadata upgrades');
      expect(row.lastSeq, 2, reason: 'newer local seq is kept');
      expect(row.lastMessagePreview, 'Hello 2', reason: 'decrypted preview is kept');
      expect(row.unreadCount, 2, reason: 'live unread count is never clobbered');
    });

    test('an authoritative summary overwrites provisional peer fields', () async {
      await dao.upsertServerMessage(
        message('m1', conversationId: 'new-chat', seq: 1, senderId: 'alice', content: 'hi'),
        ensureConversation: const ProvisionalConversationHint(
          peerId: 'alice',
          peerName: 'Alice (Ali)',
        ),
        incrementUnread: true,
      );

      await dao.upsertConversation(
        conversation(
          'new-chat',
          selfId: 'me',
          peerId: 'alice',
          peerName: 'Alice',
          peerNickname: 'Ali',
          lastSeq: 1,
          unreadCount: 1,
          // The authoritative summary carries the same message back as
          // ciphertext; the already-decrypted preview must win.
          lastMessage: message('m1', conversationId: 'new-chat', seq: 1,
              senderId: 'alice', content: 'e2ee:v1:{"ct":"secret"}'),
        ),
        selfId: 'me',
      );

      final row = (await dao.conversation('new-chat'))!;
      expect(row.peerName, 'Alice');
      expect(row.peerNickname, 'Ali');
      expect(row.lastSeq, 1);
      expect(row.lastMessagePreview, 'hi', reason: 'the decrypted preview survives');
      expect(row.unreadCount, 1);
    });
  });

}
