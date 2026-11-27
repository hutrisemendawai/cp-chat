import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/storage/token_store.dart';

import 'support/factories.dart';

class _Store extends TokenStore {
  @override
  Future<String?> readUserId() async => 'self';
}

class _Api extends ApiClient {
  _Api(super.tokenStore);

  List<Conversation> summaries = [];
  List<Message> serverMessages = [];
  final requests = <int>[];
  int pageSize = 2;
  Completer<void>? conversationsGate;

  /// Conversation summaries served by the single conversation endpoint.
  final Map<String, Conversation> fetched = {};
  final List<String> conversationRequests = [];
  Completer<void>? conversationGate;
  Object? conversationError;

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async {
    await conversationsGate?.future;
    return summaries;
  }

  @override
  Future<Conversation> conversation(String id) async {
    conversationRequests.add(id);
    final gate = conversationGate;
    if (gate != null) await gate.future;
    final error = conversationError;
    if (error != null) throw error;
    final summary = fetched[id];
    if (summary == null) {
      throw ApiException('conversation_not_found', 'not found', statusCode: 404);
    }
    return summary;
  }

  @override
  Future<SyncResult> sync(
    String conversationId, {
    required int afterSeq,
    int limit = 200,
  }) async {
    requests.add(afterSeq);
    final ordered =
        serverMessages
            .where(
              (m) => m.conversationId == conversationId && m.seq > afterSeq,
            )
            .toList()
          ..sort((a, b) => a.seq.compareTo(b.seq));
    final count = pageSize < limit ? pageSize : limit;
    return SyncResult(
      messages: ordered.take(count).toList(),
      latestSeq: serverMessages
          .where((m) => m.conversationId == conversationId)
          .fold(0, (int max, m) => m.seq > max ? m.seq : max),
    );
  }
}

Message _encrypted(int seq, {String sender = 'peer', String id = ''}) =>
    message(
      id.isEmpty ? 'm$seq' : id,
      seq: seq,
      senderId: sender,
      content: 'e2ee:v1:$seq',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ChatDao dao;
  late _Store store;
  late _Api api;
  late ChatSocket socket;
  late List<int> decrypted;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(db);
    store = _Store();
    api = _Api(store);
    decrypted = [];
    socket = ChatSocket(
      dao,
      api,
      store,
      decrypt:
          (
            conversationId,
            clientMsgId,
            senderId,
            content, {
            required isGroup,
          }) async {
            final seq = int.parse(content.split(':').last);
            decrypted.add(seq);
            return 'plain $seq';
          },
    );
  });

  tearDown(() async {
    await socket.dispose();
    await db.close();
  });

  test(
    'forward pages decrypt in order and readable rows are not replayed',
    () async {
      api.serverMessages = List.generate(5, (i) => _encrypted(i + 1));
      api.summaries = [
        conversation(
          'conv-1',
          selfId: 'self',
          lastSeq: 5,
          lastMessage: api.serverMessages.last,
        ),
      ];
      await socket.syncAll();
      expect(api.requests, [0, 2, 4]);
      expect(decrypted, [1, 2, 3, 4, 5]);
      expect((await dao.message('m5'))?.content, 'plain 5');
      await socket.syncAll();
      expect(decrypted, [1, 2, 3, 4, 5]);
      expect(api.requests, [0, 2, 4]);
    },
  );

  test('recovers a missing latest at or below the local maximum', () async {
    final latest = _encrypted(3);
    api.serverMessages = [_encrypted(1), _encrypted(2), latest];
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 3, lastMessage: latest),
    ];
    await dao.upsertServerMessage(message('m5', seq: 5));
    await socket.syncAll();
    expect(api.requests, [2, 0, 2]);
    expect(decrypted, [1, 2, 3]);
    expect((await dao.message('m3'))?.content, 'plain 3');
  });

  test('recovers an unreadable latest at the cursor', () async {
    final latest = _encrypted(3);
    api.serverMessages = [_encrypted(1), _encrypted(2), latest];
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 3, lastMessage: latest),
    ];
    await dao.upsertServerMessage(
      message('m3', seq: 3, content: undecryptableContent),
    );
    await socket.syncAll();
    expect(api.requests, [2, 0, 2]);
    expect(decrypted, [1, 2, 3]);
    expect((await dao.message('m3'))?.content, 'plain 3');
  });

  test('bounded recovery resumes on the next sync', () async {
    api.pageSize = 1;
    api.serverMessages = List.generate(52, (i) => _encrypted(i + 1));
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 52, lastMessage: api.serverMessages.last),
    ];
    await dao.upsertServerMessage(message('m53', seq: 53));
    await socket.syncAll();
    expect(await dao.message('m52'), isNull);
    await socket.syncAll();
    expect((await dao.message('m52'))?.content, 'plain 52');
    expect(decrypted, List.generate(52, (i) => i + 1));
    expect(api.requests.where((cursor) => cursor == 0), hasLength(1));
  });

  test('does not decrypt a different message returned for recovery', () async {
    final latest = _encrypted(3);
    api.serverMessages = [_encrypted(3, id: 'different')];
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 3, lastMessage: latest),
    ];
    await dao.upsertServerMessage(message('m5', seq: 5));
    await socket.syncAll();
    expect(decrypted, isEmpty);
    expect(await dao.message('m3'), isNull);
    expect(await dao.message('different'), isNull);
  });

  test(
    'concurrent sync and delivery serialize and decrypt only once',
    () async {
      final gate = Completer<void>();
      api.conversationsGate = gate;
      api.serverMessages = [_encrypted(1), _encrypted(2)];
      api.summaries = [
        conversation(
          'conv-1',
          selfId: 'self',
          lastSeq: 2,
          lastMessage: api.serverMessages.last,
        ),
      ];
      final sync = socket.syncAll();
      final live = socket.storeServerMessages([api.serverMessages.last]);
      gate.complete();
      await Future.wait([sync, live]);
      expect(decrypted, [1, 2]);
      expect((await dao.message('m2'))?.content, 'plain 2');
    },
  );

  test(
    'a concurrent duplicate waits for decryption and reuses plaintext',
    () async {
      await socket.dispose();
      final entered = Completer<void>();
      final release = Completer<void>();
      socket = ChatSocket(
        dao,
        api,
        store,
        decrypt:
            (
              conversationId,
              clientMsgId,
              senderId,
              content, {
              required isGroup,
            }) async {
              decrypted.add(1);
              entered.complete();
              await release.future;
              return 'plain 1';
            },
      );
      final frame = _encrypted(1);
      final first = socket.storeServerMessages([frame]);
      await entered.future;
      final second = socket.storeServerMessages([frame]);
      release.complete();
      await Future.wait([first, second]);
      expect(decrypted, [1]);
      expect((await dao.message('m1'))?.content, 'plain 1');
    },
  );

  test('a gap in a sync page does not advance the receiving chain', () async {
    api.serverMessages = [_encrypted(2)];
    api.summaries = [
      conversation(
        'conv-1',
        selfId: 'self',
        lastSeq: 2,
        lastMessage: api.serverMessages.last,
      ),
    ];
    await socket.syncAll();
    expect(decrypted, isEmpty);
    expect(await dao.message('m2'), isNull);
  });

  test('a gap in one conversation does not block other conversations', () async {
    final first = _encrypted(2);
    final second = message('other', conversationId: 'conv-2', seq: 1, content: 'hello');
    api.serverMessages = [first, second];
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 2, lastMessage: first),
      conversation('conv-2', selfId: 'self', lastSeq: 1, lastMessage: second),
    ];
    await socket.syncAll();
    expect((await dao.message('other'))?.content, 'hello');
  });

  test('history remains available safely when forward sync has a gap', () async {
    final first = _encrypted(3);
    final second = _encrypted(4);
    await dao.upsertConversation(conversation('conv-1', selfId: 'self'));
    await socket.storeServerMessages([second, first]);
    expect((await dao.message('m3'))?.content, undecryptableContent);
    expect((await dao.message('m4'))?.content, undecryptableContent);
    expect(decrypted, isEmpty);
  });

  test('own optimistic plaintext survives an encrypted echo', () async {
    final frame = _encrypted(1, sender: 'self');
    await dao.enqueueOutgoing(
      clientMsgId: 'm1',
      conversationId: 'conv-1',
      senderId: 'self',
      type: 'text',
      content: 'my text',
      wireContent: frame.content,
      createdAt: frame.createdAt,
    );
    api.serverMessages = [frame];
    api.summaries = [
      conversation('conv-1', selfId: 'self', lastSeq: 1, lastMessage: frame),
    ];
    await socket.syncAll();
    expect(decrypted, isEmpty);
    expect((await dao.message('m1'))?.content, 'my text');
  });

  test(
    'unavailable keys and own encrypted echoes store safe placeholders',
    () async {
      await socket.dispose();
      socket = ChatSocket(
        dao,
        api,
        store,
        decrypt:
            (
              conversationId,
              clientMsgId,
              senderId,
              content, {
              required isGroup,
            }) async {
              if (senderId == 'self') return content;
              return null;
            },
      );
      api.serverMessages = [_encrypted(1), _encrypted(2, sender: 'self')];
      api.summaries = [
        conversation(
          'conv-1',
          selfId: 'self',
          lastSeq: 2,
          lastMessage: api.serverMessages.last,
        ),
      ];
      await socket.syncAll();
      expect((await dao.message('m1'))?.content, undecryptableContent);
      expect((await dao.message('m2'))?.content, undecryptableContent);
      expect(
        (await dao.conversation('conv-1'))?.lastMessagePreview,
        isNot(contains('e2ee:v1:')),
      );
    },
  );

  group('unknown-conversation hydration', () {
    Map<String, dynamic> messageFrame(int seq, {String sender = 'alice'}) => {
      'type': 'message',
      'message_id': 'srv-$seq',
      'conversation_id': 'new-chat',
      'seq': seq,
      'sender_id': sender,
      'sender_name': 'Alice',
      'sender_avatar_url': 'alice/avatar.jpg',
      'conversation_type': 'direct',
      'conversation_name': null,
      'client_msg_id': 'm$seq',
      'msg_type': 'text',
      'content': 'e2ee:v1:$seq',
      'created_at': DateTime.utc(2026, 1, 1, 0, 0, seq).toIso8601String(),
    };

    test('a burst of live frames costs exactly one hydration request', () async {
      api.conversationGate = Completer<void>();
      api.fetched['new-chat'] = conversation(
        'new-chat',
        selfId: 'self',
        peerId: 'alice',
        peerName: 'Alice',
        peerNickname: 'Al',
        peerAvatarKey: 'alice/avatar.jpg',
        lastSeq: 5,
        unreadCount: 5,
        // The authoritative summary echoes the newest body as ciphertext; the
        // already-decrypted local row resolves it.
        lastMessage: message(
          'm5',
          conversationId: 'new-chat',
          seq: 5,
          senderId: 'alice',
          content: 'e2ee:v1:5',
        ),
      );

      // Deliver seq 1..5 rapidly; the provisional row must appear after seq 1,
      // well before the gated HTTP call resolves.
      final deliveries = [
        for (var seq = 1; seq <= 5; seq += 1)
          socket.handleServerFrameForTesting(messageFrame(seq)),
      ];
      await deliveries[0];
      final provisional = await dao.conversation('new-chat');
      expect(provisional, isNotNull, reason: 'provisional row appears immediately');
      expect(provisional!.peerName, 'Alice');
      expect(provisional.lastSeq, 1);

      await Future.wait(deliveries);
      api.conversationGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(api.conversationRequests, ['new-chat'], reason: 'single-flight dedupe');

      final hydrated = (await dao.conversation('new-chat'))!;
      expect(hydrated.peerNickname, 'Al');
      expect(hydrated.peerAvatarUrl, 'alice/avatar.jpg');
      expect(hydrated.lastSeq, 5);
      expect(hydrated.unreadCount, 5);
      expect(hydrated.lastMessagePreview, 'plain 5');
      expect((await dao.watchMessages('new-chat').first), hasLength(5));
    });

    test('a transient hydration failure retries on the next message', () async {
      api.conversationError = Exception('offline');

      await socket.handleServerFrameForTesting(messageFrame(1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await dao.conversation('new-chat'))!.lastMessagePreview, 'plain 1');

      api.conversationError = null;
      api.fetched['new-chat'] = conversation(
        'new-chat',
        selfId: 'self',
        peerId: 'alice',
        peerName: 'Alice',
        peerNickname: 'Al',
        lastSeq: 2,
      );
      await socket.handleServerFrameForTesting(messageFrame(2));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(api.conversationRequests, hasLength(2));
      expect((await dao.conversation('new-chat'))!.peerNickname, 'Al');
    });

    test('a 403/404 hydration deletes the conversation locally', () async {
      api.fetched.remove('new-chat');
      await socket.handleServerFrameForTesting(messageFrame(1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await dao.conversation('new-chat'), isNull);
    });

    test('conversation_updated emits on the update stream', () async {
      final emitted = <String>[];
      final sub = socket.conversationUpdatedEvents.listen(emitted.add);
      addTearDown(sub.cancel);

      api.fetched['new-chat'] = conversation(
        'new-chat',
        selfId: 'self',
        peerId: 'alice',
        peerName: 'Alice',
        lastSeq: 0,
      );
      await socket.handleServerFrameForTesting({
        'type': 'conversation_updated',
        'conversation_id': 'new-chat',
      });
      await Future<void>.delayed(Duration.zero);

      expect(emitted, ['new-chat']);
      expect((await dao.conversation('new-chat'))!.peerName, 'Alice');
    });

    test('a late hydration response after disconnect does not write', () async {
      api.conversationGate = Completer<void>();
      api.fetched['new-chat'] = conversation(
        'new-chat',
        selfId: 'self',
        peerId: 'alice',
        peerName: 'Alice',
        lastSeq: 1,
      );
      final delivery = socket.handleServerFrameForTesting(messageFrame(1));
      await Future<void>.delayed(Duration.zero);

      await socket.disconnect();
      api.conversationGate!.complete();
      await delivery;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The provisional row was persisted before disconnect; the late
      // authoritative summary is dropped (no peer fields applied).
      final row = await dao.conversation('new-chat');
      expect(row?.peerNickname, isNull);
    });
  });
}
