import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
