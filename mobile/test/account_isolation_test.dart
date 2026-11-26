import 'dart:async';
import 'dart:io';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_paths.dart';
import 'package:cp_chat/core/account/account_scope.dart';
import 'package:cp_chat/core/account/account_store.dart';
import 'package:cp_chat/core/crypto/e2ee_manager.dart';
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

class _MemoryTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAllValues() async => Map.of(data);
}

class _InMemoryServerApi extends ApiClient {
  _InMemoryServerApi(super.tokenStore, {required this.currentUserId});

  final String currentUserId;
  final Map<String, PublicKeyBundle> publishedKeys = {};
  final Map<String, int> keyEpochs = {};
  final Map<String, DateTime> rotatedAtByUser = {};
  final Map<String, List<Conversation>> conversationsByUser = {};
  final Map<String, List<Message>> messagesByConv = {};
  Completer<void>? conversationsGate;

  @override
  Future<int> publishKeys(
    PublicKeyBundle bundle, {
    bool historyWatermark = true,
  }) async {
    final prev = publishedKeys[currentUserId];
    publishedKeys[currentUserId] = bundle;
    if (prev != null && prev.identityKey != bundle.identityKey) {
      keyEpochs[currentUserId] = (keyEpochs[currentUserId] ?? 1) + 1;
      rotatedAtByUser[currentUserId] = DateTime.now().toUtc();
    } else {
      keyEpochs.putIfAbsent(currentUserId, () => 1);
      rotatedAtByUser.putIfAbsent(currentUserId, () => DateTime.now().toUtc());
    }
    return bundle.prekeys.length;
  }

  @override
  Future<MyKeyStatus> keysMe() async {
    final bundle = publishedKeys[currentUserId];
    if (bundle == null) {
      throw ApiException('keys_not_found', 'Not published', statusCode: 404);
    }
    return MyKeyStatus(
      userId: currentUserId,
      identityKey: bundle.identityKey,
      signingKey: bundle.signingKey,
      oneTimePrekeys: bundle.prekeys.length,
      keyEpoch: keyEpochs[currentUserId] ?? 1,
      rotatedAt: rotatedAtByUser[currentUserId],
    );
  }

  @override
  Future<int> myPrekeyCount() async => (await keysMe()).oneTimePrekeys;

  @override
  Future<int> addPrekeys(List<PublicPrekey> prekeys) async => prekeys.length;

  @override
  Future<RemotePrekeyBundle> prekeyBundle(String userId) async {
    final bundle = publishedKeys[userId];
    if (bundle == null) {
      throw ApiException('keys_not_found', 'Missing bundle', statusCode: 404);
    }
    final otp = bundle.prekeys.isEmpty ? null : bundle.prekeys.first;
    return RemotePrekeyBundle(
      userId: userId,
      identityKey: bundle.identityKey,
      signingKey: bundle.signingKey,
      signedPrekeyId: bundle.signedPrekeyId,
      signedPrekey: bundle.signedPrekey,
      signedPrekeySignature: bundle.signedPrekeySignature,
      oneTimePrekeyId: otp?.keyId,
      oneTimePrekey: otp?.publicKey,
    );
  }

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async {
    await conversationsGate?.future;
    return conversationsByUser[currentUserId] ?? const [];
  }

  @override
  Future<SyncResult> sync(
    String conversationId, {
    required int afterSeq,
    int limit = 200,
  }) async {
    final all = (messagesByConv[conversationId] ?? const [])
        .where((m) => m.seq > afterSeq)
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final latest = (messagesByConv[conversationId] ?? const [])
        .fold<int>(0, (max, m) => m.seq > max ? m.seq : max);
    return SyncResult(messages: all.take(limit).toList(), latestSeq: latest);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDirs dirs;
  late _MemoryTokenStore tokenStore;
  late DbGate dbGate;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cpchat_iso_');
    dirs = AppDirs.forTesting(root);
    await dirs.initialize();
    tokenStore = _MemoryTokenStore();
    dbGate = DbGate();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('Multi-account isolation R1 + R2', () {
    test('A -> logout -> B (empty, distinct keys) -> logout -> A (history intact, missed E2EE decrypts, outbox kept)', () async {
      final acctA = accountIdForUser('alice');
      final acctB = accountIdForUser('bob');
      final pathsA = await AccountPaths.resolve(acctA, dirs);
      final pathsB = await AccountPaths.resolve(acctB, dirs);
      final storeA = AccountStore(tokenStore, acctA);
      final storeB = AccountStore(tokenStore, acctB);

      // Shared server state across users.
      final peerService = E2eeService(prekeyCount: 3);
      final peerKeys = await peerService.generateKeyMaterial(startPrekeyId: 500);
      final peerPublic = await peerService.buildPublicBundle(peerKeys);

      final apiA = _InMemoryServerApi(tokenStore, currentUserId: 'alice');
      apiA.publishedKeys['peer'] = peerPublic;

      // ---- 1. Alice signs in, seeds E2EE chat + unsent outbox ----
      final scopeA1 = AccountScope(accountId: acctA, userId: 'alice', epoch: 1);
      final dbA1 = AppDatabase.forAccount(pathsA);
      final daoA1 = ChatDao(dbA1, scope: scopeA1);
      final e2eeA1 = E2eeManager(
        tokenStore: tokenStore,
        accountStore: storeA,
        scope: scopeA1,
        api: apiA,
      );
      await e2eeA1.bootstrap();
      final aliceIdentity1 = apiA.publishedKeys['alice']!.identityKey;

      await daoA1.upsertConversation(
        conversation('conv-ap', selfId: 'alice', peerId: 'peer', peerName: 'Peer'),
        selfId: 'alice',
      );
      // Peer sends encrypted msg 1 to Alice.
      final aliceBundle = await apiA.prekeyBundle('alice');
      final env1 = await peerService.encrypt(
        peerId: 'alice',
        plaintext: 'hello alice 1',
        local: peerKeys,
        bundle: aliceBundle,
      );
      final plain1 = await e2eeA1.plaintextFor(
        'm1',
        'conv-ap',
        env1.toContent(),
        isGroup: false,
        senderId: 'peer',
      );
      expect(plain1, 'hello alice 1');
      await daoA1.upsertServerMessage(
        message('m1', conversationId: 'conv-ap', seq: 1, senderId: 'peer', content: plain1),
      );
      // Alice queues an offline outbox message.
      await daoA1.enqueueOutgoing(
        clientMsgId: 'out-1',
        conversationId: 'conv-ap',
        senderId: 'alice',
        type: 'text',
        content: 'offline draft',
        wireContent: 'wire-out-1',
        createdAt: DateTime.utc(2026, 11, 26, 9, 0),
      );

      // Alice logs out (standard logout: flush E2EE, close DB, retain partition).
      scopeA1.beginClose();
      await e2eeA1.flush();
      await dbGate.run(pathsA.dbFile.path, dbA1.close);
      await tokenStore.clear();

      // ---- 2. Bob signs in on the SAME device ----
      final apiB = _InMemoryServerApi(tokenStore, currentUserId: 'bob')
        ..publishedKeys.addAll(apiA.publishedKeys);
      final scopeB = AccountScope(accountId: acctB, userId: 'bob', epoch: 2);
      final dbB = AppDatabase.forAccount(pathsB);
      final daoB = ChatDao(dbB, scope: scopeB);
      final e2eeB = E2eeManager(
        tokenStore: tokenStore,
        accountStore: storeB,
        scope: scopeB,
        api: apiB,
      );
      await e2eeB.bootstrap();

      // R1 assertions: Bob sees NONE of Alice's conversations, messages, outbox, or keys.
      expect(await daoB.conversations(), isEmpty);
      expect(await daoB.pendingOutbox(), isEmpty);
      expect(apiB.publishedKeys['bob']!.identityKey, isNot(aliceIdentity1));
      // Alice's keys in secure storage remain untouched.
      expect(await storeA.readE2eeKeys(), isNotNull);
      expect(await storeB.readE2eeKeys(), isNot(await storeA.readE2eeKeys()));

      // Bob logs out.
      scopeB.beginClose();
      await e2eeB.flush();
      await dbGate.run(pathsB.dbFile.path, dbB.close);
      await tokenStore.clear();

      // ---- 3. Peer sends 2 encrypted messages while Alice is signed out ----
      final env2 = await peerService.encrypt(
        peerId: 'alice',
        plaintext: 'missed message 2',
        local: peerKeys,
      );
      final env3 = await peerService.encrypt(
        peerId: 'alice',
        plaintext: 'missed message 3',
        local: peerKeys,
      );
      final m2 = message(
        'm2',
        conversationId: 'conv-ap',
        seq: 2,
        senderId: 'peer',
        content: env2.toContent(),
      );
      final m3 = message(
        'm3',
        conversationId: 'conv-ap',
        seq: 3,
        senderId: 'peer',
        content: env3.toContent(),
      );
      apiA.messagesByConv['conv-ap'] = [
        message('m1', conversationId: 'conv-ap', seq: 1, senderId: 'peer', content: env1.toContent()),
        m2,
        m3,
      ];
      apiA.conversationsByUser['alice'] = [
        conversation(
          'conv-ap',
          selfId: 'alice',
          peerId: 'peer',
          peerName: 'Peer',
          lastSeq: 3,
          lastMessage: m3,
        ),
      ];

      // ---- 4. Alice logs back in (R2) ----
      final scopeA2 = AccountScope(accountId: acctA, userId: 'alice', epoch: 3);
      final dbA2 = AppDatabase.forAccount(pathsA);
      addTearDown(dbA2.close);
      final daoA2 = ChatDao(dbA2, scope: scopeA2);
      final e2eeA2 = E2eeManager(
        tokenStore: tokenStore,
        accountStore: storeA,
        scope: scopeA2,
        api: apiA,
      );
      await e2eeA2.bootstrap();

      // Alice did NOT rotate her identity key.
      expect(apiA.publishedKeys['alice']!.identityKey, aliceIdentity1);
      expect(e2eeA2.hasKeyMismatch, isFalse);

      // History + outbox readable offline immediately before sync!
      expect((await daoA2.message('m1'))?.content, 'hello alice 1');
      expect((await daoA2.pendingOutbox()).map((o) => o.clientMsgId), ['out-1']);

      // Sync pulls missed messages 2 & 3 and decrypts them in order using restored ratchets!
      final socketA2 = ChatSocket(
        daoA2,
        apiA,
        tokenStore,
        scope: scopeA2,
        decrypt: (convId, msgId, senderId, content, {required isGroup}) =>
            e2eeA2.plaintextFor(
              msgId,
              convId,
              content,
              isGroup: isGroup,
              senderId: senderId,
            ),
      );
      addTearDown(socketA2.dispose);
      await socketA2.syncAll(selfId: 'alice');

      expect((await daoA2.message('m1'))?.content, 'hello alice 1');
      expect((await daoA2.message('m2'))?.content, 'missed message 2');
      expect((await daoA2.message('m3'))?.content, 'missed message 3');
    });

    test('stale async sync started under A and released after beginClose never touches B DB', () async {
      final acctA = accountIdForUser('alice');
      final acctB = accountIdForUser('bob');
      final pathsA = await AccountPaths.resolve(acctA, dirs);
      final pathsB = await AccountPaths.resolve(acctB, dirs);

      final scopeA = AccountScope(accountId: acctA, userId: 'alice', epoch: 1);
      final dbA = AppDatabase.forAccount(pathsA);
      final daoA = ChatDao(dbA, scope: scopeA);
      final apiA = _InMemoryServerApi(tokenStore, currentUserId: 'alice');
      final gate = Completer<void>();
      apiA.conversationsGate = gate;
      apiA.messagesByConv['conv-a'] = [
        message('ma1', conversationId: 'conv-a', seq: 1, content: 'alice secret'),
      ];
      apiA.conversationsByUser['alice'] = [
        conversation('conv-a', selfId: 'alice', lastSeq: 1),
      ];
      final socketA = ChatSocket(daoA, apiA, tokenStore, scope: scopeA);

      // Kick off sync under A, paused mid-flight.
      final inFlight = socketA.syncAll(selfId: 'alice');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Alice begins closing; Bob opens his own partition.
      scopeA.beginClose();
      await dbGate.run(pathsA.dbFile.path, dbA.close);

      final scopeB = AccountScope(accountId: acctB, userId: 'bob', epoch: 2);
      final dbB = AppDatabase.forAccount(pathsB);
      addTearDown(dbB.close);
      final daoB = ChatDao(dbB, scope: scopeB);

      // Release A's stalled HTTP call.
      gate.complete();
      await inFlight;
      await socketA.dispose();

      // B's DB is completely untouched; no exception thrown.
      expect(await daoB.conversations(), isEmpty);
      expect(await daoB.message('ma1'), isNull);
    });

    test('rapid A -> logout -> A loop via DbGate never fails with database locked/closed', () async {
      final acctA = accountIdForUser('alice');
      final pathsA = await AccountPaths.resolve(acctA, dirs);

      for (var i = 0; i < 6; i += 1) {
        final db = await dbGate.run(pathsA.dbFile.path, () async => AppDatabase.forAccount(pathsA));
        final dao = ChatDao(db);
        await dao.upsertServerMessage(
          message('m-$i', conversationId: 'conv-1', seq: i + 1, content: 'round $i'),
        );
        await dbGate.run(pathsA.dbFile.path, db.close);
      }

      final verifyDb = AppDatabase.forAccount(pathsA);
      addTearDown(verifyDb.close);
      final rows = await ChatDao(verifyDb).watchMessages('conv-1').first;
      expect(rows, hasLength(6));
    });

    test('media caches are distinct per account and isolated on disk', () async {
      final acctA = accountIdForUser('alice');
      final acctB = accountIdForUser('bob');
      final pathsA = await AccountPaths.resolve(acctA, dirs);
      final pathsB = await AccountPaths.resolve(acctB, dirs);

      final cacheA = AccountMediaCache(accountId: acctA, mediaDir: pathsA.mediaCacheDir);
      final cacheB = AccountMediaCache(accountId: acctB, mediaDir: pathsB.mediaCacheDir);

      expect(identical(cacheA, cacheB), isFalse);
      expect(cacheA.mediaDir.path, isNot(cacheB.mediaDir.path));
      expect(accountMediaCacheKey(acctA, 'img/1.jpg'), isNot(accountMediaCacheKey(acctB, 'img/1.jpg')));

      await pathsA.mediaCacheDir.create(recursive: true);
      await pathsB.mediaCacheDir.create(recursive: true);
      final fileA = File('${pathsA.mediaCacheDir.path}/a.bin')..writeAsStringSync('A');
      final fileB = File('${pathsB.mediaCacheDir.path}/b.bin')..writeAsStringSync('B');

      await cacheA.clearAccountCache();
      expect(await fileA.exists(), isFalse);
      expect(await fileB.exists(), isTrue);
    });

    test('key divergence sets keyMismatch, blocks encrypted send, and resetEncryption recovers', () async {
      final acctA = accountIdForUser('alice');
      final storeA = AccountStore(tokenStore, acctA);
      final scopeA = AccountScope(accountId: acctA, userId: 'alice', epoch: 1);

      final api = _InMemoryServerApi(tokenStore, currentUserId: 'alice');
      final peerService = E2eeService(prekeyCount: 2);
      final peerKeys = await peerService.generateKeyMaterial();
      api.publishedKeys['peer'] = await peerService.buildPublicBundle(peerKeys);

      // Seed local keys on device 1.
      final service1 = E2eeService(prekeyCount: 2);
      final localKeys = await service1.generateKeyMaterial();
      await storeA.writeE2eeKeys(await service1.exportKeyMaterial(localKeys));

      // Server holds DIFFERENT identity key (published from device 2).
      final otherDeviceKeys = await E2eeService(prekeyCount: 2).generateKeyMaterial();
      api.publishedKeys['alice'] = await E2eeService(prekeyCount: 2).buildPublicBundle(otherDeviceKeys);
      api.keyEpochs['alice'] = 2;

      final manager = E2eeManager(
        tokenStore: tokenStore,
        accountStore: storeA,
        scope: scopeA,
        api: api,
      );
      await manager.bootstrap();

      // Local keys NOT silently overwritten; mismatch flagged; outbound encrypt blocked!
      expect(manager.hasKeyMismatch, isTrue);
      final blocked = await manager.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'should be blocked',
        isGroup: false,
        peerId: 'peer',
      );
      expect(blocked, isNull);

      // User taps "Reset encryption on this device" -> fresh keys published, sending unblocked.
      await manager.resetEncryption();
      expect(manager.hasKeyMismatch, isFalse);
      expect(api.keyEpochs['alice'], 3);
      final sent = await manager.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'works again',
        isGroup: false,
        peerId: 'peer',
      );
      expect(sent, isNotNull);
      expect(isEncryptedContent(sent!), isTrue);
    });
  });
}
