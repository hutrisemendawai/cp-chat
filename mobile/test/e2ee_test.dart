import 'dart:convert';

import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the bundle Alice would fetch for Bob from the server, given Bob's
/// locally generated material. This mirrors the REST `/keys/:id` response.
Future<RemotePrekeyBundle> bundleFor(
  LocalKeyMaterial owner, {
  String userId = 'bob',
  int prekeyIndex = 0,
  bool includeOneTime = true,
}) async {
  final public = await E2eeService().buildPublicBundle(owner);
  final prekey = public.prekeys[prekeyIndex];
  return RemotePrekeyBundle(
    userId: userId,
    identityKey: public.identityKey,
    signingKey: public.signingKey,
    signedPrekeyId: public.signedPrekeyId,
    signedPrekey: public.signedPrekey,
    signedPrekeySignature: public.signedPrekeySignature,
    oneTimePrekeyId: includeOneTime ? prekey.keyId : null,
    oneTimePrekey: includeOneTime ? prekey.publicKey : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2eeService alice;
  late E2eeService bob;
  late LocalKeyMaterial aliceKeys;
  late LocalKeyMaterial bobKeys;

  setUp(() async {
    alice = E2eeService(prekeyCount: 3);
    bob = E2eeService(prekeyCount: 3);
    aliceKeys = await alice.generateKeyMaterial(startPrekeyId: 10);
    bobKeys = await bob.generateKeyMaterial(startPrekeyId: 100);
  });

  test('publishes an identity key and a signed prekey signature', () async {
    final bundle = await alice.buildPublicBundle(aliceKeys);

    expect(bundle.identityKey, isNotEmpty);
    expect(bundle.signingKey, isNotEmpty);
    expect(bundle.signedPrekey, isNotEmpty);
    expect(bundle.signedPrekeySignature, isNotEmpty);
    expect(bundle.prekeys, hasLength(3));
    // Private material is never part of the upload.
    expect(jsonEncode({
      'identity': bundle.identityKey,
      'signing': bundle.signingKey,
      'signed_prekey': bundle.signedPrekey,
    }), isNot(contains('private')));
  });

  test('a peer can verify the signed prekey against the identity key', () async {
    final bundle = await bundleFor(bobKeys);
    expect(await alice.verifyBundle(bundle), isTrue);
  });

  test('rejects a substituted prekey signature', () async {
    final legitimate = await bundleFor(bobKeys);
    final forgedPrekey = (await E2eeService().generateKeyMaterial()).signedPrekeyKeyPair;
    final forgedPublic = await forgedPrekey.extractPublicKey();

    final tampered = RemotePrekeyBundle(
      userId: legitimate.userId,
      identityKey: legitimate.identityKey,
      signingKey: legitimate.signingKey,
      signedPrekeyId: legitimate.signedPrekeyId,
      // A different public key with the original signature must not verify.
      signedPrekey: base64Encode(forgedPublic.bytes),
      signedPrekeySignature: legitimate.signedPrekeySignature,
      oneTimePrekeyId: legitimate.oneTimePrekeyId,
      oneTimePrekey: legitimate.oneTimePrekey,
    );

    expect(await alice.verifyBundle(tampered), isFalse);
    await expectLater(
      alice.initiateSession(local: aliceKeys, bundle: tampered),
      throwsA(isA<E2eeException>()),
    );
  });

  test('Alice and Bob exchange messages in both directions', () async {
    final bundle = await bundleFor(bobKeys);

    final first = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'hello bob',
      local: aliceKeys,
      bundle: bundle,
    );
    expect(first.toContent().startsWith(e2eePrefix), isTrue);

    // Bob decrypts the first message and learns Alice's session.
    final received = await bob.decrypt(
      peerId: 'alice',
      envelope: first,
      local: bobKeys,
    );
    expect(received.plaintext, 'hello bob');

    // Bob replies on his own sending chain.
    final reply = await bob.encrypt(
      peerId: 'alice',
      plaintext: 'hi alice',
      local: bobKeys,
    );
    final replyReceived = await alice.decrypt(
      peerId: 'bob',
      envelope: reply,
      local: aliceKeys,
    );
    expect(replyReceived.plaintext, 'hi alice');

    // And Alice continues on her sending chain.
    final second = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'how are you',
      local: aliceKeys,
    );
    final secondReceived = await bob.decrypt(
      peerId: 'alice',
      envelope: second,
      local: bobKeys,
    );
    expect(secondReceived.plaintext, 'how are you');
  });

  test('uses a different key for every message in a chain', () async {
    final bundle = await bundleFor(bobKeys);

    final first = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'same text',
      local: aliceKeys,
      bundle: bundle,
    );
    final second = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'same text',
      local: aliceKeys,
    );

    expect(first.index, 0);
    expect(second.index, 1);
    expect(second.nonce, isNot(first.nonce));
    expect(second.ciphertext, isNot(first.ciphertext));
  });

  test('skips forward when an earlier message never arrives', () async {
    final bundle = await bundleFor(bobKeys);

    final m0 = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'zero',
      local: aliceKeys,
      bundle: bundle,
    );
    final m1 = await alice.encrypt(peerId: 'bob', plaintext: 'one', local: aliceKeys);
    final m2 = await alice.encrypt(peerId: 'bob', plaintext: 'two', local: aliceKeys);
    expect([m0.index, m1.index, m2.index], [0, 1, 2]);

    // Bob receives m0 to establish the session, then m2 (m1 was lost).
    expect(
      (await bob.decrypt(peerId: 'alice', envelope: m0, local: bobKeys)).plaintext,
      'zero',
    );
    expect(
      (await bob.decrypt(peerId: 'alice', envelope: m2, local: bobKeys)).plaintext,
      'two',
    );
  });

  test('rejects a replayed message from an earlier chain position', () async {
    final bundle = await bundleFor(bobKeys);

    final first = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'first',
      local: aliceKeys,
      bundle: bundle,
    );
    final second = await alice.encrypt(peerId: 'bob', plaintext: 'second', local: aliceKeys);

    await bob.decrypt(peerId: 'alice', envelope: first, local: bobKeys);
    await bob.decrypt(peerId: 'alice', envelope: second, local: bobKeys);

    // Replaying the first message after the chain moved on must fail rather
    // than decrypt twice.
    await expectLater(
      bob.decrypt(peerId: 'alice', envelope: first, local: bobKeys),
      throwsA(isA<E2eeException>()),
    );
  });

  test('rejects tampered ciphertext', () async {
    final bundle = await bundleFor(bobKeys);
    final message = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'integrity',
      local: aliceKeys,
      bundle: bundle,
    );

    final bytes = base64Decode(message.ciphertext);
    bytes[0] ^= 0xff;
    final tampered = EncryptedEnvelope(
      identityKey: message.identityKey,
      ephemeralKey: message.ephemeralKey,
      signedPrekeyId: message.signedPrekeyId,
      oneTimePrekeyId: message.oneTimePrekeyId,
      index: message.index,
      ciphertext: base64Encode(bytes),
      nonce: message.nonce,
      mac: message.mac,
    );

    await expectLater(
      bob.decrypt(peerId: 'alice', envelope: tampered, local: bobKeys),
      throwsA(anything),
    );
  });

  test('works without a one-time prekey (signed prekey only)', () async {
    final bundle = await bundleFor(bobKeys, includeOneTime: false);

    final message = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'no otp',
      local: aliceKeys,
      bundle: bundle,
    );
    expect(message.oneTimePrekeyId, isNull);

    final received = await bob.decrypt(peerId: 'alice', envelope: message, local: bobKeys);
    expect(received.plaintext, 'no otp');
  });

  test('two sessions to different peers stay independent', () async {
    final carol = E2eeService(prekeyCount: 2);
    final carolKeys = await carol.generateKeyMaterial(startPrekeyId: 500);
    final bobBundle = await bundleFor(bobKeys);
    final carolBundle = await bundleFor(carolKeys, userId: 'carol');


    final toBob = await alice.encrypt(
      peerId: 'bob',
      plaintext: 'for bob',
      local: aliceKeys,
      bundle: bobBundle,
    );
    final toCarol = await alice.encrypt(
      peerId: 'carol',
      plaintext: 'for carol',
      local: aliceKeys,
      bundle: carolBundle,
    );

    expect((await bob.decrypt(peerId: 'alice', envelope: toBob, local: bobKeys)).plaintext,
        'for bob');
    expect(
      (await carol.decrypt(peerId: 'alice', envelope: toCarol, local: carolKeys)).plaintext,
      'for carol',
    );
  });

  group('envelope encoding', () {
    test('round-trips through the wire body', () async {
      final bundle = await bundleFor(bobKeys);
        final message = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'round trip',
        local: aliceKeys,
        bundle: bundle,
      );

      final content = message.toContent();
      final decoded = decodeEnvelope(content);
      expect(decoded, isNotNull);
      expect(decoded!.ciphertext, message.ciphertext);
      expect(decoded.index, message.index);
      expect(isEncryptedContent(content), isTrue);
    });

    test('leaves plaintext bodies alone', () {
      expect(isEncryptedContent('good morning'), isFalse);
      expect(decodeEnvelope('good morning'), isNull);
    });

    test('returns null for a corrupt prefixed body', () {
      expect(decodeEnvelope('${e2eePrefix}not-json'), isNull);
    });
  });
}
