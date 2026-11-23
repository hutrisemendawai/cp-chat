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

  group('1:1 session plumbing', () {
    test('a fresh responder decrypts the envelope decoded from the wire body', () async {
      final bundle = await bundleFor(bobKeys);
      final sent = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'from the wire',
        local: aliceKeys,
        bundle: bundle,
      );

      final envelope = decodeEnvelope(sent.toContent());
      expect(envelope, isNotNull);

      final received = await bob.decrypt(
        peerId: 'alice',
        envelope: envelope!,
        local: bobKeys,
      );
      expect(received.plaintext, 'from the wire');
    });

    test('the opening body carries X3DH context and the reply omits it', () async {
      final bundle = await bundleFor(bobKeys);
      final first = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'open',
        local: aliceKeys,
        bundle: bundle,
      );
      expect(first.ephemeralKey, isNotNull);
      expect(first.signedPrekeyId, bundle.signedPrekeyId);
      expect(first.oneTimePrekeyId, bundle.oneTimePrekeyId);

      await bob.decrypt(peerId: 'alice', envelope: first, local: bobKeys);
      final reply = await bob.encrypt(peerId: 'alice', plaintext: 'reply', local: bobKeys);

      expect(reply.ephemeralKey, isNull);
      expect(reply.signedPrekeyId, isNull);
      expect(reply.oneTimePrekeyId, isNull);
      expect(
        (await alice.decrypt(peerId: 'bob', envelope: reply, local: aliceKeys)).plaintext,
        'reply',
      );
    });

    test('a reply cannot be decrypted from scratch without the opening message', () async {
      final bundle = await bundleFor(bobKeys);
      final first = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'open',
        local: aliceKeys,
        bundle: bundle,
      );
      await bob.decrypt(peerId: 'alice', envelope: first, local: bobKeys);
      final reply = await bob.encrypt(peerId: 'alice', plaintext: 'orphan', local: bobKeys);

      final fresh = E2eeService(prekeyCount: 1);
      final freshKeys = await fresh.generateKeyMaterial(startPrekeyId: 900);
      await expectLater(
        fresh.decrypt(peerId: 'bob', envelope: reply, local: freshKeys),
        throwsA(isA<E2eeException>()),
      );
    });
  });

  /// The physical-device symptom: a peer's later messages stopped decrypting
  /// after an earlier one had worked, with no error visible anywhere.
  group('session recovery after a peer loses its state', () {
    Future<E2eeService> bobAfterLoss() async {
      // Same identity keys, fresh service: exactly what a reinstall/restart with
      // no persisted session looks like.
      final restarted = E2eeService(prekeyCount: 3);
      return restarted;
    }

    test('a re-initiation is accepted while the old session is still held', () async {
      final first = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'before restart',
        local: aliceKeys,
        bundle: await bundleFor(bobKeys),
      );
      await bob.decrypt(peerId: 'alice', envelope: first, local: bobKeys);

      // Bob lost his sessions and opens a new one to the same Alice.
      final restarted = await bobAfterLoss();
      final reopened = await restarted.encrypt(
        peerId: 'alice',
        plaintext: 'after restart',
        local: bobKeys,
        bundle: await bundleFor(aliceKeys, userId: 'alice'),
      );

      // Alice still holds the old session. This used to throw a MAC error and
      // render every later message as a placeholder.
      final received = await alice.decrypt(
        peerId: 'bob',
        envelope: reopened,
        local: aliceKeys,
      );
      expect(received.plaintext, 'after restart');
    });

    test('follow-up messages flow on the new session in both directions', () async {
      final opening = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'one',
        local: aliceKeys,
        bundle: await bundleFor(bobKeys),
      );
      await bob.decrypt(peerId: 'alice', envelope: opening, local: bobKeys);

      final restarted = await bobAfterLoss();
      final reopen = await restarted.encrypt(
        peerId: 'alice',
        plaintext: 'two',
        local: bobKeys,
        bundle: await bundleFor(aliceKeys, userId: 'alice'),
      );
      expect(
        (await alice.decrypt(peerId: 'bob', envelope: reopen, local: aliceKeys)).plaintext,
        'two',
      );

      // Alice replies on the promoted session; Bob reads it.
      final reply = await alice.encrypt(peerId: 'bob', plaintext: 'three', local: aliceKeys);
      expect(
        (await restarted.decrypt(peerId: 'alice', envelope: reply, local: bobKeys)).plaintext,
        'three',
      );

      // And Bob's next message continues the same session.
      final next = await restarted.encrypt(peerId: 'alice', plaintext: 'four', local: bobKeys);
      expect(
        (await alice.decrypt(peerId: 'bob', envelope: next, local: aliceKeys)).plaintext,
        'four',
      );
    });

    test('an unconfirmed initiation re-attaches its X3DH context', () async {
      // A peer that lost the session must be able to rebuild it from any later
      // message, not only the first one after the loss.
      final opening = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'zero',
        local: aliceKeys,
        bundle: await bundleFor(bobKeys),
      );
      expect(opening.ephemeralKey, isNotNull);

      // Nothing came back yet, so Alice keeps describing the session.
      final second = await alice.encrypt(peerId: 'bob', plaintext: 'one', local: aliceKeys);
      expect(second.ephemeralKey, isNotNull);
      expect(second.ephemeralKey, opening.ephemeralKey);
      expect(second.oneTimePrekeyId, opening.oneTimePrekeyId);

      // A peer that has never seen Alice's session can start from `second`.
      final freshBob = E2eeService(prekeyCount: 3);
      expect(
        (await freshBob.decrypt(peerId: 'alice', envelope: second, local: bobKeys)).plaintext,
        'one',
      );
    });

    test('the context stops being sent once the peer has answered', () async {
      final bundle = await bundleFor(bobKeys);
      final opening = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'open',
        local: aliceKeys,
        bundle: bundle,
      );
      await bob.decrypt(peerId: 'alice', envelope: opening, local: bobKeys);
      final reply = await bob.encrypt(peerId: 'alice', plaintext: 'ack', local: bobKeys);
      await alice.decrypt(peerId: 'bob', envelope: reply, local: aliceKeys);

      final later = await alice.encrypt(peerId: 'bob', plaintext: 'steady', local: aliceKeys);
      expect(later.ephemeralKey, isNull);
      expect(later.signedPrekeyId, isNull);
      expect(
        (await bob.decrypt(peerId: 'alice', envelope: later, local: bobKeys)).plaintext,
        'steady',
      );
    });

    test('a failed out-of-order decryption does not consume the skipped message', () async {
      final bundle = await bundleFor(bobKeys);
      final m0 = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'zero',
        local: aliceKeys,
        bundle: bundle,
      );
      final m1 = await alice.encrypt(peerId: 'bob', plaintext: 'one', local: aliceKeys);
      final m2 = await alice.encrypt(peerId: 'bob', plaintext: 'two', local: aliceKeys);
      await bob.decrypt(peerId: 'alice', envelope: m0, local: bobKeys);

      // A corrupted copy of m2 arrives before m1; its index forces the receiver
      // to skip past m1. If that skip were committed before the MAC check, the
      // genuine m1 would be permanently unreachable.
      final corrupt = EncryptedEnvelope(
        identityKey: m2.identityKey,
        index: m2.index,
        ciphertext: m2.ciphertext,
        nonce: m2.nonce,
        mac: '${m2.mac.substring(0, m2.mac.length - 4)}AAAA',
      );
      await expectLater(
        bob.decrypt(peerId: 'alice', envelope: corrupt, local: bobKeys),
        throwsA(anything),
      );

      expect(
        (await bob.decrypt(peerId: 'alice', envelope: m1, local: bobKeys)).plaintext,
        'one',
      );
      expect(
        (await bob.decrypt(peerId: 'alice', envelope: m2, local: bobKeys)).plaintext,
        'two',
      );
    });

    test('a replayed opening message does not rewind the cursor', () async {
      final bundle = await bundleFor(bobKeys);
      final opening = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'zero',
        local: aliceKeys,
        bundle: bundle,
      );
      final next = await alice.encrypt(peerId: 'bob', plaintext: 'one', local: aliceKeys);
      await bob.decrypt(peerId: 'alice', envelope: opening, local: bobKeys);
      await bob.decrypt(peerId: 'alice', envelope: next, local: bobKeys);

      await expectLater(
        bob.decrypt(peerId: 'alice', envelope: opening, local: bobKeys),
        throwsA(isA<E2eeException>()),
      );
    });

    test('simultaneous initiation settles on one session for both peers', () async {
      // Both sides open a session at once, each using the other's bundle.
      final aliceToBob = await alice.encrypt(
        peerId: 'bob',
        plaintext: 'from alice',
        local: aliceKeys,
        bundle: await bundleFor(bobKeys),
      );
      final bobToAlice = await bob.encrypt(
        peerId: 'alice',
        plaintext: 'from bob',
        local: bobKeys,
        bundle: await bundleFor(aliceKeys, userId: 'alice'),
      );

      // Each reads the other's opening message.
      expect(
        (await bob.decrypt(peerId: 'alice', envelope: aliceToBob, local: bobKeys)).plaintext,
        'from alice',
      );
      expect(
        (await alice.decrypt(peerId: 'bob', envelope: bobToAlice, local: aliceKeys)).plaintext,
        'from bob',
      );

      // Both keep working: the loser's chain is retained as an alternate, and
      // each side's next message is readable by the other.
      final aliceNext = await alice.encrypt(peerId: 'bob', plaintext: 'a2', local: aliceKeys);
      expect(
        (await bob.decrypt(peerId: 'alice', envelope: aliceNext, local: bobKeys)).plaintext,
        'a2',
      );
      final bobNext = await bob.encrypt(peerId: 'alice', plaintext: 'b2', local: bobKeys);
      expect(
        (await alice.decrypt(peerId: 'bob', envelope: bobNext, local: aliceKeys)).plaintext,
        'b2',
      );
    });
  });
}
