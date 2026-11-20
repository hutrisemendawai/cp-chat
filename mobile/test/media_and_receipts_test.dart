import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/media/media_service.dart';

import 'support/factories.dart';

void main() {
  group('media content encoding', () {
    test('round-trips a bare object key', () {
      final parsed = splitMediaContent('owner/2026/11/file.jpg');
      expect(parsed.key, 'owner/2026/11/file.jpg');
      expect(parsed.caption, isNull);
      expect(joinMediaContent(parsed.key, parsed.caption), 'owner/2026/11/file.jpg');
    });

    test('round-trips a key with a caption', () {
      final parsed = splitMediaContent('owner/2026/11/file.jpg|Look at this');
      expect(parsed.key, 'owner/2026/11/file.jpg');
      expect(parsed.caption, 'Look at this');
      expect(joinMediaContent(parsed.key, parsed.caption), 'owner/2026/11/file.jpg|Look at this');
    });

    test('treats an empty caption as absent', () {
      final parsed = splitMediaContent('key.pdf|');
      expect(parsed.key, 'key.pdf');
      expect(parsed.caption, isNull);
    });
  });

  group('group read receipts', () {
    late AppDatabase database;
    late ChatDao dao;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      dao = ChatDao(database);
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> seedMessages() async {
      for (var seq = 1; seq <= 3; seq += 1) {
        final clientMsgId = 'c$seq';
        await dao.enqueueOutgoing(
          clientMsgId: clientMsgId,
          conversationId: 'group-1',
          senderId: 'me',
          type: 'text',
          content: 'message $seq',
          createdAt: DateTime.utc(2026, 1, seq),
        );
        await dao.upsertServerMessage(
          message(
            clientMsgId,
            conversationId: 'group-1',
            seq: seq,
            senderId: 'me',
            content: 'message $seq',
            createdAt: DateTime.utc(2026, 1, seq),
          ),
        );
      }
      // Someone else's message must never pick up a read tally.
      await dao.upsertServerMessage(
        message('theirs', conversationId: 'group-1', seq: 4, senderId: 'them'),
      );
    }

    test('reading up to a seq marks every earlier own message', () async {
      await seedMessages();

      await dao.applyReadReceipt(
        conversationId: 'group-1',
        selfId: 'me',
        upToSeq: 3,
        readCount: 3,
        memberCount: 8,
      );

      final rows = await dao.watchMessages('group-1').first;
      final mine = rows.where((row) => row.senderId == 'me').toList();
      expect(mine.map((row) => row.readCount), [3, 3, 3]);
      expect(mine.map((row) => row.memberCount), [8, 8, 8]);
      expect(rows.firstWhere((row) => row.senderId == 'them').readCount, isNull);
    });

    test('a later receipt only advances the matching range', () async {
      await seedMessages();

      await dao.applyReadReceipt(
        conversationId: 'group-1',
        selfId: 'me',
        upToSeq: 1,
        readCount: 1,
        memberCount: 8,
      );
      await dao.applyReadReceipt(
        conversationId: 'group-1',
        selfId: 'me',
        upToSeq: 3,
        readCount: 4,
        memberCount: 8,
      );

      final mine = (await dao.watchMessages('group-1').first)
          .where((row) => row.senderId == 'me')
          .toList();
      expect(mine.map((row) => row.readCount), [4, 4, 4]);
    });

    test('a replayed lower count never regresses the tally', () async {
      await seedMessages();

      await dao.applyReadReceipt(
        conversationId: 'group-1',
        selfId: 'me',
        upToSeq: 3,
        readCount: 5,
        memberCount: 8,
      );
      await dao.applyReadReceipt(
        conversationId: 'group-1',
        selfId: 'me',
        upToSeq: 3,
        readCount: 2,
        memberCount: 8,
      );

      final mine = (await dao.watchMessages('group-1').first)
          .where((row) => row.senderId == 'me')
          .toList();
      expect(mine.every((row) => row.readCount == 5), isTrue);
    });

    test('read cursor only counts messages from others', () async {
      await seedMessages();

      // Own messages reach seq 3; a message from someone else is seq 4.
      expect(await dao.localMaxSeq('group-1'), 4);
      expect(await dao.latestSeqFromOthers('group-1', 'me'), 4);

      await dao.upsertServerMessage(
        message('mine-later', conversationId: 'group-1', seq: 5, senderId: 'me'),
      );
      expect(await dao.localMaxSeq('group-1'), 5);
      expect(await dao.latestSeqFromOthers('group-1', 'me'), 4);
    });

    test('stores the group avatar and type from the server', () async {
      await dao.upsertConversations(
        [
          conversation(
            'group-1',
            selfId: 'me',
            type: 'group',
            name: 'Team',
            avatarKey: 'owner/2026/11/avatar.jpg',
          ),
        ],
        selfId: 'me',
      );

      final row = await dao.conversation('group-1');
      expect(row!.type, 'group');
      expect(row.name, 'Team');
      expect(row.avatarUrl, 'owner/2026/11/avatar.jpg');
    });

    test('deleting a conversation removes its messages and outbox', () async {
      await seedMessages();

      await dao.deleteConversation('group-1');

      expect(await dao.conversation('group-1'), isNull);
      expect(await dao.watchMessages('group-1').first, isEmpty);
      expect(await dao.pendingOutbox(), isEmpty);
    });
  });
}
