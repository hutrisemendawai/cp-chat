import 'package:cp_chat/core/crypto/e2ee_manager.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory secure storage so the manager can be exercised without the
/// platform keychain.
class _MemoryTokenStore extends TokenStore {
  _MemoryTokenStore({this.userId});

  final String? userId;
  String? keyBlob;
  String? sessionBlob;

  @override
  Future<String?> readUserId() async => userId;

  @override
  Future<String?> readE2eeKeys() async => keyBlob;

  @override
  Future<void> writeE2eeKeys(String json) async => keyBlob = json;

  @override
  Future<String?> readE2eeSessions() async => sessionBlob;

  @override
  Future<void> writeE2eeSessions(String json) async => sessionBlob = json;
}

/// Serves prekey bundles and records publishes instead of hitting the network.
class _FakeApi extends ApiClient {
  _FakeApi(super.tokenStore, {this.bundles = const {}});

  final Map<String, RemotePrekeyBundle> bundles;
  final List<PublicKeyBundle> published = [];

  @override
  Future<int> publishKeys(PublicKeyBundle bundle) async {
    published.add(bundle);
    return bundle.prekeys.length;
  }

  @override
  Future<int> addPrekeys(List<PublicPrekey> prekeys) async => prekeys.length;

  @override
  Future<int> myPrekeyCount() async => 100;

  @override
  Future<RemotePrekeyBundle> prekeyBundle(String userId) async {
    final bundle = bundles[userId];
    if (bundle == null) {
      throw ApiException('keys_not_found', 'This user has not published keys', statusCode: 404);
    }
    return bundle;
  }
}

RemotePrekeyBundle _bundleFor(PublicKeyBundle public, {String userId = 'bob'}) {
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

typedef _Recipient = ({
  _MemoryTokenStore store,
  _FakeApi api,
  E2eeService service,
  LocalKeyMaterial keys,
  E2eeManager manager,
});

Future<_Recipient> _recipient({required String userId, int startPrekeyId = 100}) async {
  final service = E2eeService(prekeyCount: 3);
  final keys = await service.generateKeyMaterial(startPrekeyId: startPrekeyId);
  final store = _MemoryTokenStore(userId: userId)
    ..keyBlob = await service.exportKeyMaterial(keys);
  final api = _FakeApi(store);
  final manager = E2eeManager(
    tokenStore: store,
    api: api,
    service: E2eeService(prekeyCount: 3),
  );
  await manager.bootstrap();
  return (store: store, api: api, service: service, keys: keys, manager: manager);
}

Future<E2eeManager> _sender(_MemoryTokenStore store, _FakeApi api) async {
  final manager = E2eeManager(tokenStore: store, api: api);
  await manager.bootstrap();
  return manager;
}

/// Manager-level tests run against the crypto service directly, because the
/// manager's storage/API seams are injected by Riverpod. What matters here is
/// that key material survives a persist/restore cycle — the failure mode that
/// would silently break every existing session after an app restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('key material persistence', () {
    test('export and import round-trip preserves every public key', () async {
      final service = E2eeService(prekeyCount: 2);
      final material = await service.generateKeyMaterial(startPrekeyId: 42);

      final serialized = await service.exportKeyMaterial(material);
      final restored = await service.importKeyMaterial(serialized);

      final original = await service.buildPublicBundle(material);
      final restoredBundle = await service.buildPublicBundle(restored);

      expect(restoredBundle.identityKey, original.identityKey);
      expect(restoredBundle.signingKey, original.signingKey);
      expect(restoredBundle.signedPrekey, original.signedPrekey);
      expect(restoredBundle.signedPrekeySignature, original.signedPrekeySignature);
      expect(
        restoredBundle.prekeys.map((prekey) => prekey.publicKey),
        original.prekeys.map((prekey) => prekey.publicKey),
      );
      expect(restored.signedPrekeyId, material.signedPrekeyId);
    });

    test('restored keys still complete a session with a peer', () async {
      // A restart must not break continuity: Alice's restored identity has to
      // verify Bob's signed prekey and produce a decryptable message.
      final alice = E2eeService(prekeyCount: 1);
      final bob = E2eeService(prekeyCount: 1);
      final bobKeys = await bob.generateKeyMaterial(startPrekeyId: 200);

      final aliceMaterial = await alice.generateKeyMaterial(startPrekeyId: 100);
      final serialized = await alice.exportKeyMaterial(aliceMaterial);
      final restoredAlice = await alice.importKeyMaterial(serialized);

      final bobPublic = await bob.buildPublicBundle(bobKeys);
      final bundle = RemotePrekeyBundle(
        userId: 'bob',
        identityKey: bobPublic.identityKey,
        signingKey: bobPublic.signingKey,
        signedPrekeyId: bobPublic.signedPrekeyId,
        signedPrekey: bobPublic.signedPrekey,
        signedPrekeySignature: bobPublic.signedPrekeySignature,
        oneTimePrekeyId: bobPublic.prekeys.first.keyId,
        oneTimePrekey: bobPublic.prekeys.first.publicKey,
      );

      final envelope = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'after restart',
        local: restoredAlice,
        bundle: bundle,
      );

      final received = await bob.decrypt(peerId: 'alice', envelope: envelope, local: bobKeys);
      expect(received.plaintext, 'after restart');
    });

    test('a serialised blob is JSON with seeds only, no plaintext secrets', () async {
      final service = E2eeService(prekeyCount: 1);
      final material = await service.generateKeyMaterial(startPrekeyId: 1);
      final serialized = await service.exportKeyMaterial(material);

      expect(serialized, contains('"identity"'));
      expect(serialized, contains('"signed_prekey"'));
      expect(serialized, isNot(contains('private')));
    });

    test('generated top-up prekeys are disjoint, ordered, and usable', () async {
      // Replenishment must not reuse ids from a spent batch, or the server
      // would discard the new keys as duplicates.
      final service = E2eeService(prekeyCount: 2);
      final material = await service.generateKeyMaterial(startPrekeyId: 10);

      final fresh = await service.generatePrekeys(count: 3, startPrekeyId: 1000);

      expect(fresh.map((prekey) => prekey.keyId), [1000, 1001, 1002]);
      final existingIds =
          (await service.buildPublicBundle(material)).prekeys.map((p) => p.keyId).toSet();
      expect(fresh.every((prekey) => !existingIds.contains(prekey.keyId)), isTrue);

      // The private half is retained so a session that used one can be decrypted.
      final combined = [
        ...material.prekeys,
        ...fresh.map((prekey) => prekey.keyPairEntry),
      ];
      final updated = LocalKeyMaterial(
        identityKeyPair: material.identityKeyPair,
        signingKeyPair: material.signingKeyPair,
        signedPrekeyId: material.signedPrekeyId,
        signedPrekeyKeyPair: material.signedPrekeyKeyPair,
        signedPrekeySignature: material.signedPrekeySignature,
        prekeys: combined,
      );
      expect(updated.prekey(1001), isNotNull);

      // And the extended material still round-trips through storage.
      final restored = await service.importKeyMaterial(
        await service.exportKeyMaterial(updated),
      );
      expect(restored.prekeys.map((p) => p.keyId).toSet(), {10, 11, 1000, 1001, 1002});
    });
  });

  group('session state export', () {
    test('a session serialises and restores with chain positions intact', () async {
      final alice = E2eeService(prekeyCount: 1);
      final bob = E2eeService(prekeyCount: 1);
      final aliceKeys = await alice.generateKeyMaterial(startPrekeyId: 10);
      final bobKeys = await bob.generateKeyMaterial(startPrekeyId: 500);
      final bobPublic = await bob.buildPublicBundle(bobKeys);

      final bundle = RemotePrekeyBundle(
        userId: 'bob',
        identityKey: bobPublic.identityKey,
        signingKey: bobPublic.signingKey,
        signedPrekeyId: bobPublic.signedPrekeyId,
        signedPrekey: bobPublic.signedPrekey,
        signedPrekeySignature: bobPublic.signedPrekeySignature,
      );

      final first = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'one',
        local: aliceKeys,
        bundle: bundle,
      );
      final session = alice.session('bob')!;
      final json = session.toJson();
      expect(json['sending']['index'], 1);

      final restored = E2eeSession.fromJson(json);
      expect(restored.sendingIndex, 1);
      expect(restored.peerId, 'bob');

      // A restored session continues the same chain the peer expects.
      final bobService = E2eeService(prekeyCount: 1);
      bobService.restoreSession(
        E2eeSession.fromJson({
          'peer_id': 'alice',
          'receiving': json['sending'],
          'sending': json['receiving'],
        }),
      );
      expect(bobService.hasSession('alice'), isTrue);
      void _ = first;
    });
  });

  group('direct chat manager', () {
    test('encrypts outbound and decrypts inbound from the sender id alone', () async {
      final bob = await _recipient(userId: 'bob');
      final bobPublic = await bob.service.buildPublicBundle(bob.keys);

      final aliceStore = _MemoryTokenStore(userId: 'alice');
      final alice = await _sender(
        aliceStore,
        _FakeApi(aliceStore, bundles: {'bob': _bundleFor(bobPublic)}),
      );

      // The peer is passed explicitly, so no UI registration is needed.
      final content = await alice.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'hello bob',
        isGroup: false,
        peerId: 'bob',
      );
      expect(isEncryptedContent(content), isTrue);
      expect(decodeEnvelope(content)!.ephemeralKey, isNotNull);

      // Bob has never seen this conversation; the sender id resolves the peer.
      final plaintext = await bob.manager.plaintextFor(
        'm-1',
        'conv-1',
        content,
        isGroup: false,
        senderId: 'alice',
      );
      expect(plaintext, 'hello bob');

      // And the reply returns on Bob's own sending chain.
      final reply = await bob.manager.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'hi alice',
        isGroup: false,
        peerId: 'alice',
      );
      expect(
        await alice.plaintextFor('m-2', 'conv-1', reply, isGroup: false, senderId: 'bob'),
        'hi alice',
      );
    });

    test('persists a session learned from inbound and resumes it after restart', () async {
      final bob = await _recipient(userId: 'bob');
      final bobPublic = await bob.service.buildPublicBundle(bob.keys);

      final aliceStore = _MemoryTokenStore(userId: 'alice');
      final alice = await _sender(
        aliceStore,
        _FakeApi(aliceStore, bundles: {'bob': _bundleFor(bobPublic)}),
      );

      final first = await alice.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'first',
        isGroup: false,
        peerId: 'bob',
      );
      expect(
        await bob.manager.plaintextFor('m-1', 'conv-1', first, isGroup: false, senderId: 'alice'),
        'first',
      );
      expect(bob.store.sessionBlob, isNotNull);
      expect(bob.store.sessionBlob, contains('"alice"'));

      final restored = E2eeManager(
        tokenStore: bob.store,
        api: bob.api,
        service: E2eeService(prekeyCount: 3),
      );
      await restored.bootstrap();

      final second = await alice.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'second',
        isGroup: false,
        peerId: 'bob',
      );
      expect(
        await restored.plaintextFor('m-2', 'conv-1', second, isGroup: false, senderId: 'alice'),
        'second',
      );
    });

    test('group chats are never encrypted or treated as ciphertext', () async {
      final bob = await _recipient(userId: 'bob');

      expect(
        await bob.manager.encryptForConversation(
          conversationId: 'group-1',
          plaintext: 'hello team',
          isGroup: true,
          peerId: 'bob',
        ),
        'hello team',
      );
      expect(
        await bob.manager.plaintextFor(
          'm-1',
          'group-1',
          'hello team',
          isGroup: true,
          senderId: 'alice',
        ),
        'hello team',
      );
    });

    test('falls back to plaintext when there is no peer or bundle', () async {
      final store = _MemoryTokenStore(userId: 'alice');
      final manager = await _sender(store, _FakeApi(store));

      expect(
        await manager.encryptForConversation(
          conversationId: 'conv-1',
          plaintext: 'no peer known',
          isGroup: false,
        ),
        'no peer known',
      );
      expect(
        await manager.encryptForConversation(
          conversationId: 'conv-1',
          plaintext: 'no keys published',
          isGroup: false,
          peerId: 'ghost',
        ),
        'no keys published',
      );
    });

    test('renders a placeholder for a body it cannot decrypt', () async {
      final bob = await _recipient(userId: 'bob');

      expect(
        await bob.manager.plaintextFor(
          'bad',
          'conv-1',
          '${e2eePrefix}not-json',
          isGroup: false,
          senderId: 'alice',
        ),
        undecryptableContent,
      );
    });

    test('leaves an own outgoing body untouched instead of breaking it', () async {
      final bob = await _recipient(userId: 'bob');
      final bobPublic = await bob.service.buildPublicBundle(bob.keys);

      final aliceStore = _MemoryTokenStore(userId: 'alice');
      final alice = await _sender(
        aliceStore,
        _FakeApi(aliceStore, bundles: {'bob': _bundleFor(bobPublic)}),
      );
      final content = await alice.encryptForConversation(
        conversationId: 'conv-1',
        plaintext: 'mine',
        isGroup: false,
        peerId: 'bob',
      );

      expect(
        await bob.manager.plaintextFor('m-1', 'conv-1', content, isGroup: false, senderId: 'bob'),
        content,
      );
    });
  });
}
