import 'dart:io';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_paths.dart';
import 'package:cp_chat/core/account/account_registry.dart';
import 'package:cp_chat/core/account/account_scope.dart';
import 'package:cp_chat/core/account/account_store.dart';
import 'package:cp_chat/core/account/account_wiper.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/media/account_media_cache.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/factories.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);
}

class _WatermarkServerApi extends ApiClient {
  _WatermarkServerApi(super.tokenStore);

  bool offline = false;
  final Map<String, List<Message>> serverMessages = {};
  final Map<String, int> clearedSeqs = {};
  final Map<String, String> convTypes = {};
  int clearAllCalls = 0;
  int clearConvCalls = 0;

  @override
  Future<int> clearConversation(String conversationId) async {
    clearConvCalls += 1;
    if (offline) throw StateError('offline');
    final latest = _latest(conversationId);
    final next = (clearedSeqs[conversationId] ?? 0) > latest
        ? clearedSeqs[conversationId]!
        : latest;
    clearedSeqs[conversationId] = next;
    return next;
  }

  @override
  Future<Map<String, int>> clearAllHistory() async {
    clearAllCalls += 1;
    if (offline) throw StateError('offline');
    final out = <String, int>{};
    for (final convId in serverMessages.keys) {
      final latest = _latest(convId);
      final next = (clearedSeqs[convId] ?? 0) > latest ? clearedSeqs[convId]! : latest;
      clearedSeqs[convId] = next;
      out[convId] = next;
    }
    return out;
  }

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async {
    return [
      for (final entry in serverMessages.entries)
        conversation(
          entry.key,
          selfId: 'alice',
          type: convTypes[entry.key] ?? 'direct',
          lastSeq: _latest(entry.key),
          lastReadSeq: clearedSeqs[entry.key] ?? 0,
          unreadCount: 0,
          lastMessage: _latestVisible(entry.key),
        ).withClearedSeq(clearedSeqs[entry.key] ?? 0),
    ];
  }

  @override
  Future<SyncResult> sync(
    String conversationId, {
    required int afterSeq,
    int limit = 200,
  }) async {
    final cleared = clearedSeqs[conversationId] ?? 0;
    final effective = afterSeq > cleared ? afterSeq : cleared;
    final list = (serverMessages[conversationId] ?? const [])
        .where((m) => m.seq > effective)
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return SyncResult(
      messages: list.take(limit).toList(),
      latestSeq: _latest(conversationId),
      clearedSeq: cleared,
    );
  }

  int _latest(String convId) => (serverMessages[convId] ?? const [])
      .fold<int>(0, (max, m) => m.seq > max ? m.seq : max);

  Message? _latestVisible(String convId) {
    final cleared = clearedSeqs[convId] ?? 0;
    final visible = (serverMessages[convId] ?? const [])
        .where((m) => m.seq > cleared)
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return visible.isEmpty ? null : visible.last;
  }
}

extension _ConvCleared on Conversation {
  Conversation withClearedSeq(int cleared) => Conversation(
        id: id,
        type: type,
        name: name,
        avatarUrl: avatarUrl,
        members: members,
        lastSeq: lastSeq,
        lastReadSeq: lastReadSeq,
        clearedSeq: cleared,
        unreadCount: unreadCount,
        createdAt: createdAt,
        lastMessage: lastMessage,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDirs dirs;
  late _MapTokenStore tokenStore;
  late AccountRegistry registry;
  late DbGate dbGate;
  late AccountWiper wiper;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cpchat_wiper_');
    dirs = AppDirs.forTesting(root);
    await dirs.initialize();
    tokenStore = _MapTokenStore();
    registry = AccountRegistry(tokenStore);
    dbGate = DbGate();
    wiper = AccountWiper(
      tokenStore: tokenStore,
      dirs: dirs,
      registry: registry,
      dbGate: dbGate,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('L1 Clear Chat & Clear All', () {
    test('L1 clears rows, keeps E2EE keys, advances watermark, and accepts seq = cleared_seq + 1', () async {
      final acct = accountIdForUser('alice');
      final paths = await AccountPaths.resolve(acct, dirs);
      final store = AccountStore(tokenStore, acct);
      final scope = AccountScope(accountId: acct, userId: 'alice', epoch: 1);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      final dao = ChatDao(db, scope: scope);
      final api = _WatermarkServerApi(tokenStore);
      final cache = AccountMediaCache(accountId: acct, mediaDir: paths.mediaCacheDir);

      await store.writeE2eeKeys('{"kept":true}');
      await paths.mediaCacheDir.create(recursive: true);
      final cachedImg = File('${paths.mediaCacheDir.path}/thumb.jpg')..writeAsStringSync('bytes');

      api.serverMessages['c1'] = [
        message('m1', conversationId: 'c1', seq: 1, content: 'old 1'),
        message('m2', conversationId: 'c1', seq: 2, content: 'old 2'),
      ];
      await dao.upsertConversations(await api.conversations(), selfId: 'alice');
      await dao.upsertServerMessages(api.serverMessages['c1']!);

      // Execute L1 Clear all chats.
      await wiper.clearAllChats(
        accountId: acct,
        dao: dao,
        api: api,
        mediaCache: cache,
      );

      expect(await dao.watchMessages('c1').first, isEmpty);
      expect(await dao.effectiveCursor('c1'), 2);
      expect(await store.readE2eeKeys(), '{"kept":true}');
      expect(await cachedImg.exists(), isFalse);
      expect(api.clearedSeqs['c1'], 2);

      // Re-sync returns ZERO historic rows.
      final socket = ChatSocket(dao, api, tokenStore, scope: scope);
      addTearDown(socket.dispose);
      await socket.syncAll(selfId: 'alice');
      expect(await dao.watchMessages('c1').first, isEmpty);

      // New message arrives at seq = cleared_seq + 1 = 3 -> accepted cleanly!
      api.serverMessages['c1']!.add(
        message('m3', conversationId: 'c1', seq: 3, content: 'brand new 3'),
      );
      await socket.syncAll(selfId: 'alice');
      final rows = await dao.watchMessages('c1').first;
      expect(rows.map((r) => r.seq), [3]);
      expect(rows.single.content, 'brand new 3');
    });

    test('offline L1 queues pending_server_clear and flushes before next syncAll', () async {
      final acct = accountIdForUser('alice');
      final paths = await AccountPaths.resolve(acct, dirs);
      final store = AccountStore(tokenStore, acct);
      final scope = AccountScope(accountId: acct, userId: 'alice', epoch: 1);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      final dao = ChatDao(db, scope: scope);
      final api = _WatermarkServerApi(tokenStore)..offline = true;

      api.serverMessages['c1'] = [
        message('m1', conversationId: 'c1', seq: 1, content: 'old 1'),
        message('m2', conversationId: 'c1', seq: 2, content: 'old 2'),
      ];
      await dao.upsertConversations(await api.conversations(), selfId: 'alice');
      await dao.upsertServerMessages(api.serverMessages['c1']!);

      await wiper.clearConversation(
        accountId: acct,
        conversationId: 'c1',
        dao: dao,
        api: api,
      );

      // Local rows cleared immediately; server clear queued; local floor = 2.
      expect(await dao.watchMessages('c1').first, isEmpty);
      expect(await dao.clearedSeqFor('c1'), 2);
      expect((await store.readPendingServerClear()).conversationIds, ['c1']);

      // Come back online -> syncAll runs beforeSync which flushes clearConversation first!
      api.offline = false;
      final socket = ChatSocket(
        dao,
        api,
        tokenStore,
        scope: scope,
        beforeSync: () => wiper.flushPendingServerClears(
          accountId: acct,
          api: api,
          dao: dao,
        ),
      );
      addTearDown(socket.dispose);
      await socket.syncAll(selfId: 'alice');

      expect(api.clearedSeqs['c1'], 2);
      expect((await store.readPendingServerClear()).isEmpty, isTrue);
      expect(await dao.watchMessages('c1').first, isEmpty);
    });
  });

  group('L2 Partition Wipe & Crash Resumption', () {
    test('deletes DB, WAL/SHM, media cache, keys, and registry entry; resumable after crash', () async {
      final acct = accountIdForUser('alice');
      final paths = await AccountPaths.resolve(acct, dirs);
      final store = AccountStore(tokenStore, acct);
      await registry.register('alice', displayName: 'Alice');
      await store.writeE2eeKeys('{"k":1}');
      await store.writeE2eeSessions('{"s":1}');
      await store.writePartitionId('pid-1');

      final db = AppDatabase.forAccount(paths);
      await ChatDao(db).upsertServerMessage(message('m1', seq: 1, content: 'secret'));
      await paths.mediaCacheDir.create(recursive: true);
      await File('${paths.mediaCacheDir.path}/x.jpg').writeAsString('img');

      await wiper.wipeAccountPartition(accountId: acct, openDb: db);

      expect(db.isClosed, isTrue);
      expect(await paths.dbFile.exists(), isFalse);
      expect(await paths.partitionDir.exists(), isFalse);
      expect(await paths.cacheDir.exists(), isFalse);
      expect(await store.readE2eeKeys(), isNull);
      expect(await store.readE2eeSessions(), isNull);
      expect(await store.readPartitionId(), isNull);
      expect(await registry.findByAccountId(acct), isNull);
      expect(await registry.pendingWipes(), isEmpty);

      // Simulate a crash mid-wipe: leftover file + wipe_pending marker.
      await paths.partitionDir.create(recursive: true);
      await paths.dbFile.writeAsString('leftover');
      await registry.markWipePending(acct);

      await wiper.resumePendingWipes();
      expect(await paths.dbFile.exists(), isFalse);
      expect(await registry.pendingWipes(), isEmpty);
    });

    test('offline L2 flags pending_l2_clear so next login clears server before syncAll', () async {
      final acct = accountIdForUser('alice');
      final api = _WatermarkServerApi(tokenStore)..offline = true;
      api.serverMessages['c1'] = [message('m1', conversationId: 'c1', seq: 1, content: 'old')];

      await wiper.wipeAccountPartition(
        accountId: acct,
        api: api,
        notifyServer: true,
      );
      expect(await registry.hasPendingL2ServerClear(acct), isTrue);

      // Next login comes online: flushPendingServerClears executes clearAllHistory first.
      api.offline = false;
      final paths = await AccountPaths.resolve(acct, dirs);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      final dao = ChatDao(db);

      await wiper.flushPendingServerClears(accountId: acct, api: api, dao: dao);
      expect(api.clearedSeqs['c1'], 1);
      expect(await registry.hasPendingL2ServerClear(acct), isFalse);
    });
  });

  group('L3 Pre-rotation backfill defence in depth & history_cleared frame', () {
    test('historic backfill drops undecryptable pre-rotation ciphertexts with 0 stub rows and at most 1 notice', () async {
      final acct = accountIdForUser('alice');
      final paths = await AccountPaths.resolve(acct, dirs);
      final scope = AccountScope(accountId: acct, userId: 'alice', epoch: 1);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      final dao = ChatDao(db, scope: scope);
      final api = _WatermarkServerApi(tokenStore);

      final rotatedAt = DateTime.utc(2026, 11, 26, 10, 0);
      // 3 old pre-rotation ciphertexts (server without watermark) + 1 post-rotation readable msg.
      api.serverMessages['c1'] = [
        message(
          'old1',
          conversationId: 'c1',
          seq: 1,
          senderId: 'peer',
          content: 'e2ee:v1:{"v":1,"ct":"old1"}',
          createdAt: rotatedAt.subtract(const Duration(minutes: 30)),
        ),
        message(
          'old2',
          conversationId: 'c1',
          seq: 2,
          senderId: 'peer',
          content: 'e2ee:v1:{"v":1,"ct":"old2"}',
          createdAt: rotatedAt.subtract(const Duration(minutes: 20)),
        ),
        message(
          'old3',
          conversationId: 'c1',
          seq: 3,
          senderId: 'peer',
          content: 'e2ee:v1:{"v":1,"ct":"old3"}',
          createdAt: rotatedAt.subtract(const Duration(minutes: 10)),
        ),
        message(
          'new4',
          conversationId: 'c1',
          seq: 4,
          senderId: 'peer',
          content: 'e2ee:v1:{"v":1,"ct":"new4"}',
          createdAt: rotatedAt.add(const Duration(minutes: 1)),
        ),
      ];

      final socket = ChatSocket(
        dao,
        api,
        tokenStore,
        scope: scope,
        serverRotatedAt: () => rotatedAt,
        decrypt: (convId, msgId, senderId, content, {required isGroup}) async {
          if (msgId == 'new4') return 'fresh decrypted message';
          return undecryptableContent;
        },
      );
      addTearDown(socket.dispose);

      await socket.syncAll(selfId: 'alice');

      final rows = await dao.watchMessages('c1').first;
      // Zero undecryptable stub rows stored!
      expect(rows.where((r) => r.content == undecryptableContent), isEmpty);
      // At most 1 neutral system notice + the 1 post-rotation message.
      expect(rows.where((r) => r.type == 'system'), hasLength(1));
      expect(rows.firstWhere((r) => r.clientMsgId == 'new4').content, 'fresh decrypted message');
    });

    test('second device applies history_cleared WebSocket frame locally', () async {
      final acct = accountIdForUser('alice');
      final paths = await AccountPaths.resolve(acct, dirs);
      final scope = AccountScope(accountId: acct, userId: 'alice', epoch: 1);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      final dao = ChatDao(db, scope: scope);
      final api = _WatermarkServerApi(tokenStore);

      await dao.upsertConversation(conversation('c1', selfId: 'alice', lastSeq: 3), selfId: 'alice');
      await dao.upsertServerMessages([
        message('m1', conversationId: 'c1', seq: 1, content: 'one'),
        message('m2', conversationId: 'c1', seq: 2, content: 'two'),
        message('m3', conversationId: 'c1', seq: 3, content: 'three'),
      ]);

      final socket = ChatSocket(dao, api, tokenStore, scope: scope);
      addTearDown(socket.dispose);

      await socket.handleServerFrameForTesting({
        'type': 'history_cleared',
        'conversation_id': 'c1',
        'cleared_seq': 2,
      });

      final remaining = await dao.watchMessages('c1').first;
      expect(remaining.map((m) => m.seq), [3]);
      expect(await dao.clearedSeqFor('c1'), 2);
    });
  });
}
