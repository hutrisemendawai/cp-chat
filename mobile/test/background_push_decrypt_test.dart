import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_paths.dart';
import 'package:cp_chat/core/account/account_registry.dart';
import 'package:cp_chat/core/account/account_store.dart';
import 'package:cp_chat/core/account/legacy_migration.dart';
import 'package:cp_chat/core/account/partition_guard.dart';
import 'package:cp_chat/core/account/partition_lock.dart';
import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/logging/app_logger.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/network/ws_client.dart';
import 'package:cp_chat/core/notifications/background_push_handler.dart';
import 'package:cp_chat/core/notifications/local_notification_service.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';

import 'support/factories.dart';

class _MemoryTokenStore extends TokenStore {
  final Map<String, String> data = {};
  bool failAllReads = false;
  bool failSessionWrites = false;
  bool deleteCalled = false;

  @override
  Future<String?> readValue(String key) async {
    if (failAllReads) return null;
    return data[key];
  }

  @override
  Future<void> writeValue(String key, String value) async {
    if (failSessionWrites && key.endsWith('e2ee_sessions')) {
      throw PlatformException(code: 'keystore_locked', message: 'simulated failure');
    }
    data[key] = value;
  }

  @override
  Future<void> deleteValue(String key) async {
    deleteCalled = true;
    data.remove(key);
  }
}

class _RecordingSink implements MessageNotificationSink {
  final List<
      ({
        String conversationId,
        String title,
        String body,
        String? messageId,
        String? accountId,
      })> shown = [];

  @override
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
    String? accountId,
  }) async {
    shown.add((
      conversationId: conversationId,
      title: title,
      body: body,
      messageId: messageId,
      accountId: accountId,
    ));
  }
}

class _FakeApi extends ApiClient {
  _FakeApi(
    super.tokenStore, {
    this.bundles = const {},
    this.syncHandler,
  });

  final Map<String, RemotePrekeyBundle> bundles;
  final Future<SyncResult> Function(String conversationId, int afterSeq, int limit)?
      syncHandler;
  final List<({String conversationId, int afterSeq, int limit})> syncCalls = [];

  @override
  Future<int> publishKeys(PublicKeyBundle bundle, {bool historyWatermark = true}) async =>
      bundle.prekeys.length;

  @override
  Future<int> addPrekeys(List<PublicPrekey> prekeys) async => prekeys.length;

  @override
  Future<int> myPrekeyCount() async => 100;

  @override
  Future<RemotePrekeyBundle> prekeyBundle(String userId) async => bundles[userId]!;

  @override
  Future<SyncResult> sync(
    String conversationId, {
    required int afterSeq,
    int limit = 200,
  }) async {
    syncCalls.add((conversationId: conversationId, afterSeq: afterSeq, limit: limit));
    final handler = syncHandler;
    if (handler != null) {
      return handler(conversationId, afterSeq, limit);
    }
    throw StateError('unexpected sync call');
  }
}

RemotePrekeyBundle _bundleFor(String userId, PublicKeyBundle public) {
  final prekey = public.prekeys.first;
  return RemotePrekeyBundle(
    userId: userId,
    identityKey: public.identityKey,
    signingKey: public.signingKey,
    signedPrekeyId: public.signedPrekeyId,
    signedPrekey: public.signedPrekey,
    signedPrekeySignature: public.signedPrekeySignature,
    oneTimePrekeyId: prekey.keyId,
    oneTimePrekey: prekey.publicKey,
  );
}

class _BobPartitionFixture {
  _BobPartitionFixture({
    required this.root,
    required this.dirs,
    required this.store,
    required this.accountId,
    required this.accountStore,
    required this.paths,
    required this.bobPublic,
    required this.aliceManager,
  });

  final Directory root;
  final AppDirs dirs;
  final _MemoryTokenStore store;
  final String accountId;
  final AccountStore accountStore;
  final AccountPaths paths;
  final PublicKeyBundle bobPublic;
  final E2eeManager aliceManager;

  static Future<_BobPartitionFixture> create({
    String bobUserId = 'bob',
    String bobStatus = 'online',
    String conversationId = 'conv-1',
    bool seedConversation = true,
    String? peerNickname,
  }) async {
    final root = await Directory.systemTemp.createTemp('cpchat_bg_fcm_');
    final dirs = AppDirs.forTesting(root);
    await dirs.initialize();

    final store = _MemoryTokenStore();
    final accountId = accountIdForUser(bobUserId);
    final accountStore = AccountStore(store, accountId);

    await store.saveSession(
      accessToken: 'acc-bob',
      refreshToken: 'ref-bob',
      userId: bobUserId,
      accountId: accountId,
    );
    await store.saveUser(User(id: bobUserId, name: 'Bob', status: bobStatus));
    await store.writeDeviceId('bob-device');
    await store.writeValue(LegacyMigration.layoutKey, LegacyMigration.layoutVersion);
    await accountStore.writePartitionId('part-bob-1');

    // Generate and store Bob's E2EE keys in Bob's account partition.
    final bobService = E2eeService(prekeyCount: 5);
    final bobKeys = await bobService.generateKeyMaterial(startPrekeyId: 100);
    await accountStore.writeE2eeKeys(await bobService.exportKeyMaterial(bobKeys));
    final bobPublic = await bobService.buildPublicBundle(bobKeys);

    // Create Bob's file-backed SQLite DB with valid account_meta markers.
    final paths = await AccountPaths.resolve(accountId, dirs);
    final db = AppDatabase.forFile(paths.dbFile);
    try {
      await db.writeMeta(PartitionGuard.ownerUserIdKey, bobUserId);
      await db.writeMeta(PartitionGuard.partitionIdKey, 'part-bob-1');
      if (seedConversation) {
        final dao = ChatDao(db);
        final conv = Conversation(
          id: conversationId,
          type: 'direct',
          members: [
            ConversationMember(
              user: User(id: bobUserId, name: 'Bob'),
              role: 'member',
              lastReadSeq: 0,
            ),
            ConversationMember(
              user: User(id: 'alice', name: 'Alice', nickname: peerNickname),
              role: 'member',
              lastReadSeq: 0,
            ),
          ],
          lastSeq: 0,
          lastReadSeq: 0,
          unreadCount: 0,
          createdAt: DateTime.utc(2026, 1, 1),
        );
        await dao.upsertConversations([conv], selfId: bobUserId);
      }
    } finally {
      await db.close();
    }

    // Set up Alice as the sender with Bob's prekey bundle.
    final aliceStore = _MemoryTokenStore();
    await aliceStore.saveSession(
      accessToken: 'acc-alice',
      refreshToken: 'ref-alice',
      userId: 'alice',
      accountId: accountIdForUser('alice'),
    );
    final aliceManager = E2eeManager(
      tokenStore: aliceStore,
      api: _FakeApi(aliceStore, bundles: {bobUserId: _bundleFor(bobUserId, bobPublic)}),
    );
    await aliceManager.bootstrap();

    return _BobPartitionFixture(
      root: root,
      dirs: dirs,
      store: store,
      accountId: accountId,
      accountStore: accountStore,
      paths: paths,
      bobPublic: bobPublic,
      aliceManager: aliceManager,
    );
  }

  Future<String> aliceEncrypt(String plaintext, {String conversationId = 'conv-1'}) async {
    return (await aliceManager.encryptForConversation(
      conversationId: conversationId,
      plaintext: plaintext,
      isGroup: false,
      peerId: 'bob',
    ))!;
  }

  Future<void> dispose() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}

Map<String, dynamic> _v2PushData({
  String conversationId = 'conv-1',
  String conversationType = 'direct',
  String conversationName = '',
  String messageId = 'srv-1',
  String clientMsgId = 'client-1',
  int seq = 1,
  String senderId = 'alice',
  String senderName = 'Alice',
  String recipientUserId = 'bob',
  String msgType = 'text',
  String? content,
  bool contentOmitted = false,
}) {
  return {
    'push_schema': '2',
    'type': msgType,
    'msg_type': msgType,
    'conversation_id': conversationId,
    'conversation_type': conversationType,
    'conversation_name': conversationName,
    'message_id': messageId,
    'client_msg_id': clientMsgId,
    'seq': '$seq',
    'sender_id': senderId,
    'sender_name': senderName,
    'recipient_user_id': recipientUserId,
    'created_at': DateTime.utc(2026, 11, 26, 12, 0, seq).toIso8601String(),
    if (content != null && !contentOmitted) 'content': content,
    if (contentOmitted) 'content_omitted': 'true',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundPushHandler — terminated E2EE decryption', () {
    test('decrypts direct E2EE push, persists plaintext & sessions, and shows real text', () async {
      final fixture = await _BobPartitionFixture.create(peerNickname: 'Al');
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ciphertext = await fixture.aliceEncrypt('Secret lunch at 12?');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handle(
        RemoteMessage(data: _v2PushData(content: ciphertext)),
      );

      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.title, 'Alice (Al)');
      expect(sink.shown.single.body, 'Secret lunch at 12?');
      expect(sink.shown.single.body, isNot(contains('e2ee:v1:')));
      expect(sink.shown.single.accountId, fixture.accountId);
      expect(sink.shown.single.conversationId, 'conv-1');

      // Plaintext is persisted in Bob's SQLite partition.
      final db = AppDatabase.forFile(fixture.paths.dbFile);
      try {
        final stored = await ChatDao(db).message('client-1');
        expect(stored, isNotNull);
        expect(stored!.content, 'Secret lunch at 12?');
        expect(stored.seq, 1);
      } finally {
        await db.close();
      }

      // Updated ratchet sessions are persisted in Bob's AccountStore.
      expect(await fixture.accountStore.readE2eeSessions(), isNotNull);
    });

    test('terminated first contact persists both the message and a conversation row',
        () async {
      // Bob has never seen this conversation: no local_conversations row yet.
      final fixture = await _BobPartitionFixture.create(seedConversation: false);
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ciphertext = await fixture.aliceEncrypt('Hi, first contact');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handle(
        RemoteMessage(data: _v2PushData(content: ciphertext)),
      );
      expect(outcome, BackgroundPushOutcome.shownDecrypted);

      final db = AppDatabase.forFile(fixture.paths.dbFile);
      try {
        final dao = ChatDao(db);
        final stored = await dao.message('client-1');
        expect(stored, isNotNull);
        expect(stored!.content, 'Hi, first contact');

        final conv = await dao.conversation('conv-1');
        expect(conv, isNotNull, reason: 'a provisional conversation row is created');
        expect(conv!.type, 'direct');
        expect(conv.peerId, 'alice');
        expect(conv.peerName, 'Alice');
        expect(conv.lastMessagePreview, 'Hi, first contact');
        expect(conv.unreadCount, 1);
      } finally {
        await db.close();
      }
    });

    test('opening the app after background decrypt skips re-decryption and decrypts seq+1 cleanly',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ct1 = await fixture.aliceEncrypt('First while terminated');
      final ct2 = await fixture.aliceEncrypt('Second after resume');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(_v2PushData(
        messageId: 'srv-1',
        clientMsgId: 'client-1',
        seq: 1,
        content: ct1,
      ));
      expect(outcome, BackgroundPushOutcome.shownDecrypted);

      // Simulate cold start of main isolate: fresh AppDatabase, fresh E2eeManager, fresh ChatSocket.
      final db = AppDatabase.forFile(fixture.paths.dbFile);
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(fixture.store);
      final mainE2ee = E2eeManager(
        tokenStore: fixture.store,
        accountStore: fixture.accountStore,
        api: api,
      );
      await mainE2ee.bootstrap();

      var decryptCalls = 0;
      final socket = ChatSocket(
        dao,
        api,
        fixture.store,
        decrypt: (conversationId, clientMsgId, senderId, body, {required isGroup}) {
          decryptCalls += 1;
          return mainE2ee.plaintextFor(
            clientMsgId,
            conversationId,
            body,
            isGroup: isGroup,
            senderId: senderId,
          );
        },
      );
      addTearDown(socket.dispose);

      // Replay seq=1 (as if REST sync returned it) + deliver seq=2.
      await socket.storeServerMessages([
        message('client-1', conversationId: 'conv-1', seq: 1, senderId: 'alice', content: ct1),
        message('client-2', conversationId: 'conv-1', seq: 2, senderId: 'alice', content: ct2),
      ]);

      final rows = await dao.watchMessages('conv-1').first;
      expect(rows.map((r) => r.content).toList(), [
        'First while terminated',
        'Second after resume',
      ]);
      expect(
        decryptCalls,
        1,
        reason: 'seq=1 was already persisted as plaintext by the background handler',
      );
    });

    test('crash-safe write order: failure committing e2ee_sessions after DB write loses zero messages',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ct1 = await fixture.aliceEncrypt('Msg 1 before crash');
      final ct2 = await fixture.aliceEncrypt('Msg 2 after crash');

      // Simulate Keystore write failure right after SQLite commit on msg 1.
      fixture.store.failSessionWrites = true;

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(_v2PushData(
        messageId: 'srv-1',
        clientMsgId: 'client-1',
        seq: 1,
        content: ct1,
      ));
      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown.single.body, 'Msg 1 before crash');

      // Re-enable Keystore writes and simulate app resuming and receiving msg 2.
      fixture.store.failSessionWrites = false;
      final db = AppDatabase.forFile(fixture.paths.dbFile);
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(fixture.store);
      final mainE2ee = E2eeManager(
        tokenStore: fixture.store,
        accountStore: fixture.accountStore,
        api: api,
      );
      await mainE2ee.bootstrap();
      final socket = ChatSocket(
        dao,
        api,
        fixture.store,
        decrypt: (cid, cmid, sid, body, {required isGroup}) => mainE2ee.plaintextFor(
          cmid,
          cid,
          body,
          isGroup: isGroup,
          senderId: sid,
        ),
      );
      addTearDown(socket.dispose);

      // Even though sessions were NOT persisted after msg 1, msg 1 is already
      // readable in SQLite and msg 2 carries initiation context / forward index
      // so the symmetric ratchet skips cleanly to index 1.
      await socket.storeServerMessages([
        message('client-1', conversationId: 'conv-1', seq: 1, senderId: 'alice', content: ct1),
        message('client-2', conversationId: 'conv-1', seq: 2, senderId: 'alice', content: ct2),
      ]);

      final rows = await dao.watchMessages('conv-1').first;
      expect(rows.map((r) => r.content).toList(), [
        'Msg 1 before crash',
        'Msg 2 after crash',
      ]);
    });

    test('fills sequence gap via /sync in ascending order and notifies with latest plaintext',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ct1 = await fixture.aliceEncrypt('One');
      final ct2 = await fixture.aliceEncrypt('Two');
      final ct3 = await fixture.aliceEncrypt('Three');

      late _FakeApi capturedApi;
      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) {
          capturedApi = _FakeApi(
            s,
            syncHandler: (cid, afterSeq, limit) async {
              expect(cid, 'conv-1');
              expect(afterSeq, 1);
              return SyncResult(
                latestSeq: 3,
                messages: [
                  message('client-2', conversationId: cid, seq: 2, senderId: 'alice', content: ct2),
                  message('client-3', conversationId: cid, seq: 3, senderId: 'alice', content: ct3),
                ],
              );
            },
          );
          return capturedApi;
        },
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // Deliver seq=1 inline first.
      expect(
        await handler.handleData(
          _v2PushData(messageId: 'srv-1', clientMsgId: 'client-1', seq: 1, content: ct1),
        ),
        BackgroundPushOutcome.shownDecrypted,
      );

      // Now push seq=3 (seq=2 push dropped): triggers /sync?after_seq=1.
      final outcome = await handler.handleData(
        _v2PushData(messageId: 'srv-3', clientMsgId: 'client-3', seq: 3, content: ct3),
      );

      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(capturedApi.syncCalls, hasLength(1));
      expect(sink.shown.last.body, 'Three');

      final db = AppDatabase.forFile(fixture.paths.dbFile);
      try {
        final rows = await ChatDao(db).watchMessages('conv-1').first;
        expect(rows.map((r) => r.content).toList(), ['One', 'Two', 'Three']);
      } finally {
        await db.close();
      }
    });

    test('offline gap does NOT advance ratchet and shows Encrypted message fallback', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ct1 = await fixture.aliceEncrypt('One');
      final ct2 = await fixture.aliceEncrypt('Two');
      final ct3 = await fixture.aliceEncrypt('Three');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(
          s,
          syncHandler: (_, _, _) async => throw const SocketException('offline'),
        ),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // Deliver seq=1 inline.
      await handler.handleData(
        _v2PushData(messageId: 'srv-1', clientMsgId: 'client-1', seq: 1, content: ct1),
      );
      final sessionsAfter1 = await fixture.accountStore.readE2eeSessions();

      // Push seq=3 while offline: sync fails -> must NOT advance ratchet past seq=1.
      final outcome = await handler.handleData(
        _v2PushData(messageId: 'srv-3', clientMsgId: 'client-3', seq: 3, content: ct3),
      );
      expect(outcome, BackgroundPushOutcome.shownFallback);
      expect(sink.shown.last.body, 'Encrypted message');
      expect(await fixture.accountStore.readE2eeSessions(), sessionsAfter1);

      // When seq=2 arrives later, it still decrypts cleanly!
      final outcome2 = await handler.handleData(
        _v2PushData(messageId: 'srv-2', clientMsgId: 'client-2', seq: 2, content: ct2),
      );
      expect(outcome2, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown.last.body, 'Two');
    });

    test('content_omitted (>4KB payload) fetches via /sync and decrypts', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final longText = 'Long secret message ' * 150;
      final ciphertext = await fixture.aliceEncrypt(longText);

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(
          s,
          syncHandler: (cid, afterSeq, limit) async => SyncResult(
            latestSeq: 1,
            messages: [
              message('client-big', conversationId: cid, seq: 1, senderId: 'alice', content: ciphertext),
            ],
          ),
        ),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(
        _v2PushData(
          messageId: 'srv-big',
          clientMsgId: 'client-big',
          seq: 1,
          contentOmitted: true,
        ),
      );

      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown.single.body, longText.trim());
    });

    test('per-account isolation: logged out, wrong account, wipe pending, owner mismatch, unmigrated',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      final ct = await fixture.aliceEncrypt('Private');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // (a) Push targeted at another user (Charlie) while Bob is signed in -> dropped.
      expect(
        await handler.handleData(_v2PushData(recipientUserId: 'charlie', content: ct)),
        BackgroundPushOutcome.droppedAccountMismatch,
      );
      expect(sink.shown, isEmpty);

      // (b) Wipe pending for Bob -> dropped.
      await AccountRegistry(fixture.store).markWipePending(fixture.accountId);
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.droppedWipePending,
      );
      expect(sink.shown, isEmpty);
      await AccountRegistry(fixture.store).clearWipePending(fixture.accountId);

      // (c) Unmigrated legacy layout -> fallback shown without touching DB or ratchet.
      await fixture.store.writeValue(LegacyMigration.layoutKey, 'v1_legacy');
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.shownFallback,
      );
      expect(sink.shown.single.body, 'Encrypted message');
      expect(await fixture.accountStore.readE2eeSessions(), isNull);
      sink.shown.clear();
      await fixture.store.writeValue(LegacyMigration.layoutKey, LegacyMigration.layoutVersion);

      // (d) account_meta owner mismatch -> dropped silently.
      await fixture.accountStore.writePartitionId('different-partition-id');
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.droppedIntegrityMismatch,
      );
      expect(sink.shown, isEmpty);
      await fixture.accountStore.writePartitionId('part-bob-1');

      // (e) Signed out -> dropped silently.
      await fixture.store.clear();
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.droppedAccountMismatch,
      );
      expect(sink.shown, isEmpty);
    });

    test('suppresses DND, self-sent, and duplicate already-persisted messages', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      final ct = await fixture.aliceEncrypt('Hello once');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // Self-sent -> suppressed.
      expect(
        await handler.handleData(_v2PushData(senderId: 'bob', content: ct)),
        BackgroundPushOutcome.suppressedPolicy,
      );
      expect(sink.shown, isEmpty);

      // DND -> suppressed.
      await fixture.store.saveUser(const User(id: 'bob', name: 'Bob', status: 'dnd'));
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.suppressedPolicy,
      );
      expect(sink.shown, isEmpty);

      // Restore online, decrypt once, then redeliver same push -> suppressedDuplicate.
      await fixture.store.saveUser(const User(id: 'bob', name: 'Bob', status: 'online'));
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.shownDecrypted,
      );
      expect(sink.shown, hasLength(1));

      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.suppressedDuplicate,
      );
      expect(sink.shown, hasLength(1));
    });

    test('renders media messages (with and without captions) and group chat plaintext', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      // Image without caption
      await handler.handleData(_v2PushData(
        messageId: 'm1',
        clientMsgId: 'c1',
        seq: 1,
        msgType: 'image',
        content: 'media/photo1.jpg',
      ));
      // Image with caption
      await handler.handleData(_v2PushData(
        messageId: 'm2',
        clientMsgId: 'c2',
        seq: 2,
        msgType: 'image',
        content: 'media/photo2.jpg|sunset',
      ));
      // File without caption
      await handler.handleData(_v2PushData(
        messageId: 'm3',
        clientMsgId: 'c3',
        seq: 3,
        msgType: 'file',
        content: 'media/doc.pdf',
      ));
      // File with caption
      await handler.handleData(_v2PushData(
        messageId: 'm4',
        clientMsgId: 'c4',
        seq: 4,
        msgType: 'file',
        content: 'media/report.pdf|report.pdf',
      ));
      // Group text
      await handler.handleData(_v2PushData(
        conversationId: 'group-1',
        conversationType: 'group',
        conversationName: 'Weekend Squad',
        messageId: 'm5',
        clientMsgId: 'c5',
        seq: 1,
        senderId: 'alice',
        senderName: 'Alice',
        msgType: 'text',
        content: 'hi all',
      ));

      expect(sink.shown.map((n) => n.body).toList(), [
        'Sent an image',
        'Photo: sunset',
        'Sent a file',
        'File: report.pdf',
        'Alice: hi all',
      ]);
      expect(sink.shown.last.title, 'Weekend Squad');
    });

    test('missing keys / locked keystore never wipes storage and falls back safely', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      final ct = await fixture.aliceEncrypt('Locked out');

      // Missing keys in AccountStore -> fallback without wiping anything.
      fixture.store.data.remove(fixture.accountStore.e2eeKeysKey);

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(_v2PushData(content: ct));
      expect(outcome, BackgroundPushOutcome.shownFallback);
      expect(sink.shown.single.body, 'Encrypted message');
      expect(fixture.store.deleteCalled, isFalse);

      // Direct Boot / Keystore unreadable (all reads return null) -> dropped cleanly, no wipe.
      sink.shown.clear();
      fixture.store.failAllReads = true;
      expect(
        await handler.handleData(_v2PushData(content: ct)),
        BackgroundPushOutcome.droppedAccountMismatch,
      );
      expect(sink.shown, isEmpty);
      expect(fixture.store.deleteCalled, isFalse);
    });

    test('delegates push to live main isolate via IsolateNameServer port without opening DB',
        () async {
      final port = ReceivePort();
      addTearDown(port.close);

      Map<String, dynamic>? receivedData;
      port.listen((dynamic message) {
        final map = message as Map;
        receivedData = Map<String, dynamic>.from(map['data'] as Map);
        (map['replyPort'] as SendPort).send(true);
      });

      final sink = _RecordingSink();
      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => throw StateError('must not read keystore when delegating'),
        notificationSinkFactory: () async => sink,
        portLookup: (name) => name == kMainIsolateFcmPortName ? port.sendPort : null,
      );

      final outcome = await handler.handleData(
        _v2PushData(content: 'e2ee:v1:{}'),
      );
      expect(outcome, BackgroundPushOutcome.delegatedToMainIsolate);
      expect(receivedData?['conversation_id'], 'conv-1');
      expect(sink.shown, isEmpty);
    });

    test('AppDirs.noBackupDirStrict refuses to fall back to applicationSupport on Android',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      const channel = MethodChannel('cpchat/storage_test_missing');
      final dirs = AppDirs(channel: channel);
      final strict = await dirs.noBackupDirStrict();
      expect(strict, isNull);
    });

    test('self-sent encrypted message in a gap advances cursor so subsequent peer message decrypts',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();

      final ct1 = await fixture.aliceEncrypt('From Alice 1');
      final ct3 = await fixture.aliceEncrypt('From Alice 3');
      // Bob sent seq=2 from another device (ciphertext unreadable to this device).
      const selfCiphertext = 'e2ee:v1:{"v":1,"ik":"aQ==","ek":"ZQ==","spk":1,"i":0,"ct":"Y3Q=","n":"bm9uY2UxMjM0NTY=","m":"bWFjMTIzNDU2Nzg5MDEyMzQ1Ng=="}';

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(
          s,
          syncHandler: (cid, afterSeq, limit) async => SyncResult(
            latestSeq: 3,
            messages: [
              message('self-2', conversationId: cid, seq: 2, senderId: 'bob', content: selfCiphertext),
              message('client-3', conversationId: cid, seq: 3, senderId: 'alice', content: ct3),
            ],
          ),
        ),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      expect(
        await handler.handleData(_v2PushData(
          messageId: 'srv-1',
          clientMsgId: 'client-1',
          seq: 1,
          content: ct1,
        )),
        BackgroundPushOutcome.shownDecrypted,
      );

      final outcome = await handler.handleData(_v2PushData(
        messageId: 'srv-3',
        clientMsgId: 'client-3',
        seq: 3,
        content: ct3,
      ));
      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown.last.body, 'From Alice 3');
    });

    test('unset layoutKey still decrypts when partition DB and account_meta are valid',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      fixture.store.data.remove(LegacyMigration.layoutKey);

      final ct = await fixture.aliceEncrypt('Layout unset recovery');
      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(_v2PushData(content: ct));
      expect(outcome, BackgroundPushOutcome.shownDecrypted);
      expect(sink.shown.single.body, 'Layout unset recovery');
    });

    test('Case 3 stale seq suppresses duplicate when a readable row exists at (conversationId, seq)',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      final ct = await fixture.aliceEncrypt('Already stored');

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      expect(
        await handler.handleData(_v2PushData(clientMsgId: 'client-1', seq: 1, content: ct)),
        BackgroundPushOutcome.shownDecrypted,
      );
      expect(
        await handler.handleData(_v2PushData(clientMsgId: 'other-id', seq: 1, content: ct)),
        BackgroundPushOutcome.suppressedDuplicate,
      );
      expect(sink.shown, hasLength(1));
    });

    test('records non-secret fallback diagnostics and drains them into AppLogger', () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final sink = _RecordingSink();
      final ct = await fixture.aliceEncrypt('Top secret body');
      fixture.store.data.remove(fixture.accountStore.e2eeKeysKey);

      final handler = BackgroundPushHandler(
        tokenStoreFactory: () => fixture.store,
        appDirsFactory: () => fixture.dirs,
        apiClientFactory: (s, _) => _FakeApi(s),
        notificationSinkFactory: () async => sink,
        portLookup: (_) => null,
      );

      final outcome = await handler.handleData(_v2PushData(content: ct));
      expect(outcome, BackgroundPushOutcome.shownFallback);

      final diagFile = File('${fixture.paths.partitionDir.path}/${BackgroundPushHandler.diagFileName}');
      expect(await diagFile.exists(), isTrue);
      final rawDiag = await diagFile.readAsString();
      expect(rawDiag, contains('noLocalKeys'));
      expect(rawDiag, isNot(contains('Top secret body')));
      expect(rawDiag, isNot(contains('e2ee:v1:')));

      final logger = AppLogger();
      await BackgroundPushHandler.drainDiagnostics(fixture.paths.partitionDir, logger);
      expect(await diagFile.exists(), isFalse);
      expect(logger.entries, hasLength(1));
      expect(logger.entries.single.tag, 'fcm_bg_diag');
      expect(logger.entries.single.meta?['fallback_reason'], 'noLocalKeys');
    });

    test('ChatSocket.ingestFcmPush preserves plaintext group content when /sync throws',
        () async {
      final fixture = await _BobPartitionFixture.create();
      addTearDown(fixture.dispose);
      final db = AppDatabase.forFile(fixture.paths.dbFile);
      addTearDown(db.close);
      final dao = ChatDao(db);
      final api = _FakeApi(
        fixture.store,
        syncHandler: (_, _, _) async => throw const SocketException('offline'),
      );
      final socket = ChatSocket(dao, api, fixture.store);
      addTearDown(socket.dispose);

      final emitted = <Message>[];
      socket.onIncomingMessage = (msg, {String? senderName}) => emitted.add(msg);

      await socket.ingestFcmPush(_v2PushData(
        conversationId: 'group-9',
        conversationType: 'group',
        conversationName: 'Ops',
        messageId: 'srv-5',
        clientMsgId: 'client-5',
        seq: 5,
        senderId: 'alice',
        senderName: 'Alice',
        msgType: 'text',
        content: 'Deploy is green',
      ));

      expect(emitted, hasLength(1));
      expect(emitted.single.content, 'Deploy is green');
    });
  });

  group('PartitionLock', () {
    test('serializes concurrent acquisitions until first holder releases', () async {
      final dir = await Directory.systemTemp.createTemp('cpchat_lock_test_');
      addTearDown(() => dir.delete(recursive: true));

      final events = <String>[];
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();

      final first = PartitionLock.withLock(dir, () async {
        events.add('first-enter');
        firstEntered.complete();
        await releaseFirst.future;
        events.add('first-exit');
      });

      await firstEntered.future;

      final second = PartitionLock.withLock(dir, () async {
        events.add('second-enter');
        events.add('second-exit');
      });

      // Give the second caller a chance to attempt acquisition while first holds it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, ['first-enter']);

      releaseFirst.complete();
      await Future.wait([first, second]);

      expect(events, ['first-enter', 'first-exit', 'second-enter', 'second-exit']);
      expect(await File('${dir.path}/${PartitionLock.lockFileName}').exists(), isFalse);
    });
  });
}
