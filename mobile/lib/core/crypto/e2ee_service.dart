import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption for 1:1 chats.
///
/// The server only ever sees public keys and ciphertext. This implements:
/// - **Identity + prekeys (X3DH):** a long-term X25519 identity key, a signed
///   prekey (signed with an Ed25519 identity signing key, so a recipient can
///   prove the prekey belongs to the claimed identity), and one-time prekeys.
/// - **Session setup:** X3DH combines both identities, an ephemeral key, and a
///   one-time prekey when available, then HKDF splits the result into two
///   independent chains — one per direction.
/// - **Symmetric-key ratchet:** each direction advances its own chain key, and
///   every message derives a fresh AES-256-GCM key from it, so a leaked message
///   key cannot decrypt earlier messages (forward secrecy per chain).
///
/// The envelope matches `backend/src/lib/e2ee.ts` and is prefixed with
/// `e2ee:v1:`. The server validates the shape but cannot decrypt it.
///
/// Scope: this is a documented subset of the Double Ratchet. Each direction has
/// its own chain, which is enough for a conversation where both sides send; a
/// full asynchronous ratchet (fresh DH per round-trip, skipped-key storage for
/// arbitrary reordering) is described in docs/e2ee.md rather than approximated
/// here. Within a chain, the `i` index lets the receiver skip ahead past
/// messages it already decrypted or that arrived out of order.
const String e2eePrefix = 'e2ee:v1:';

final Uint8List _rootInfo = Uint8List.fromList(utf8.encode('cpchat-x3dh-v1'));
final Uint8List _initiatorSendInfo = Uint8List.fromList(utf8.encode('cpchat-chain-initiator-send'));
final Uint8List _responderSendInfo = Uint8List.fromList(utf8.encode('cpchat-chain-responder-send'));

/// A freshly generated one-time prekey, both halves.
class GeneratedPrekey {
  const GeneratedPrekey({required this.keyId, required this.public, required this.keyPairEntry});

  final int keyId;

  /// Public half for upload.
  final PublicPrekey public;

  /// Private half for the local key store.
  final ({int keyId, SimpleKeyPair keyPair}) keyPairEntry;
}

/// A prekey the local device wants the server to hand out.
class PublicPrekey {
  const PublicPrekey({required this.keyId, required this.publicKey});

  final int keyId;
  final String publicKey;
}

/// The public half of a device's key material, uploaded to the server.
class PublicKeyBundle {
  const PublicKeyBundle({
    required this.identityKey,
    required this.signingKey,
    required this.signedPrekeyId,
    required this.signedPrekey,
    required this.signedPrekeySignature,
    required this.prekeys,
  });

  final String identityKey;
  final String signingKey;
  final int signedPrekeyId;
  final String signedPrekey;
  final String signedPrekeySignature;
  final List<PublicPrekey> prekeys;
}

/// Locally generated key material. Private keys never leave the device.
class LocalKeyMaterial {
  const LocalKeyMaterial({
    required this.identityKeyPair,
    required this.signingKeyPair,
    required this.signedPrekeyId,
    required this.signedPrekeyKeyPair,
    required this.signedPrekeySignature,
    required this.prekeys,
  });

  final SimpleKeyPair identityKeyPair;
  final SimpleKeyPair signingKeyPair;
  final int signedPrekeyId;
  final SimpleKeyPair signedPrekeyKeyPair;
  final String signedPrekeySignature;
  final List<({int keyId, SimpleKeyPair keyPair})> prekeys;

  /// The one-time prekey with `keyId`, needed to decrypt a first message that
  /// used it. Returned keys are not removed here; the caller manages rotation.
  SimpleKeyPair? prekey(int keyId) {
    for (final prekey in prekeys) {
      if (prekey.keyId == keyId) return prekey.keyPair;
    }
    return null;
  }
}

/// A prekey bundle fetched from the server for a recipient.
class RemotePrekeyBundle {
  const RemotePrekeyBundle({
    required this.userId,
    required this.identityKey,
    required this.signingKey,
    required this.signedPrekeyId,
    required this.signedPrekey,
    required this.signedPrekeySignature,
    this.oneTimePrekeyId,
    this.oneTimePrekey,
  });

  final String userId;
  final String identityKey;
  final String signingKey;
  final int signedPrekeyId;
  final String signedPrekey;
  final String signedPrekeySignature;
  final int? oneTimePrekeyId;
  final String? oneTimePrekey;
}

/// One direction's ratchet state.
class RatchetChain {
  RatchetChain({required this.key, required this.index});

  SecretKeyData key;
  int index;

  Map<String, dynamic> toJson() => {'key': base64Encode(key.bytes), 'index': index};
}

/// An established session with one peer: a chain for sending and one for
/// receiving, which is what makes a bidirectional conversation work without a
/// full DH ratchet.
class E2eeSession {
  // Named parameters keep the API readable while the fields stay private; the
  // lint's suggested `this._sending` form is not valid for named parameters.
  E2eeSession({
    required this.peerId,
    required RatchetChain sending,
    required RatchetChain receiving,
    // ignore: prefer_initializing_formals
  })  : _sending = sending,
        // ignore: prefer_initializing_formals
        _receiving = receiving;

  final String peerId;

  /// Chain state. The chain objects are mutated in place (key and index
  /// advance) as messages are sent and received; the references never change.
  final RatchetChain _sending;
  final RatchetChain _receiving;

  int get sendingIndex => _sending.index;
  int get receivingIndex => _receiving.index;

  Map<String, dynamic> toJson() => {
        'peer_id': peerId,
        'sending': _sending.toJson(),
        'receiving': _receiving.toJson(),
      };

  static E2eeSession fromJson(Map<String, dynamic> json) => E2eeSession(
        peerId: json['peer_id'] as String,
        sending: _chainFromJson(json['sending'] as Map<String, dynamic>),
        receiving: _chainFromJson(json['receiving'] as Map<String, dynamic>),
      );
}

RatchetChain _chainFromJson(Map<String, dynamic> json) => RatchetChain(
      key: SecretKeyData(base64Decode(json['key'] as String)),
      index: (json['index'] as num).toInt(),
    );

/// The on-the-wire encrypted body, prefixed with `e2ee:v1:`.
///
/// `ik`, `ct`, `n`, and `m` are always present. The X3DH initiation fields
/// (`ek`, `spk`, `opk`) are only sent with the *first* message of a session;
/// the responder's replies and later messages omit them because the receiver
/// already holds the session.
class EncryptedEnvelope {
  const EncryptedEnvelope({
    required this.identityKey,
    required this.ciphertext,
    required this.nonce,
    required this.mac,
    required this.index,
    this.ephemeralKey,
    this.signedPrekeyId,
    this.oneTimePrekeyId,
  });

  final String identityKey;
  final String? ephemeralKey;
  final int? signedPrekeyId;
  final int? oneTimePrekeyId;
  final String ciphertext;
  final String nonce;

  /// AES-GCM authentication tag (16 bytes, base64).
  final String mac;

  /// Position in the sender's chain, so the receiver can advance to it.
  final int index;

  /// True when this body opens a session and carries the X3DH context.
  bool get isInitiation => ephemeralKey != null;

  /// Serialises to the `e2ee:v1:{...}` body the server relays. The server
  /// validates `v`, `ik`, `ct`, `n`, and `m`, and relays the optional
  /// initiation fields untouched.
  String toContent() => '$e2eePrefix${jsonEncode(toJson())}';

  Map<String, dynamic> toJson() => {
        'v': 1,
        'ik': identityKey,
        if (ephemeralKey != null) 'ek': ephemeralKey,
        if (signedPrekeyId != null) 'spk': signedPrekeyId,
        if (oneTimePrekeyId != null) 'opk': oneTimePrekeyId,
        'i': index,
        'ct': ciphertext,
        'n': nonce,
        'm': mac,
      };

  static EncryptedEnvelope fromJson(Map<String, dynamic> json) => EncryptedEnvelope(
        identityKey: json['ik'] as String,
        ephemeralKey: json['ek'] as String?,
        signedPrekeyId: (json['spk'] as num?)?.toInt(),
        oneTimePrekeyId: (json['opk'] as num?)?.toInt(),
        index: (json['i'] as num?)?.toInt() ?? 0,
        ciphertext: json['ct'] as String,
        nonce: json['n'] as String,
        mac: json['m'] as String,
      );
}

/// A decrypted inbound message.
class DecryptedMessage {
  const DecryptedMessage({required this.plaintext, required this.envelope});

  final String plaintext;
  final EncryptedEnvelope envelope;
}

/// Thrown when a body cannot be decrypted (wrong key, tampered ciphertext, or
/// a session that has not been established).
class E2eeException implements Exception {
  const E2eeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Values an envelope needs to let the *receiver* build its side of a session.
/// They are only consumed on the first message of a session; afterwards the
/// receiver already has the session and ignores them.
class _SessionOrigin {
  const _SessionOrigin({
    required this.ephemeral,
    required this.signedPrekeyId,
    this.oneTimePrekeyId,
  });

  final SimpleKeyPair ephemeral;
  final int signedPrekeyId;
  final int? oneTimePrekeyId;
}

class E2eeService {
  E2eeService({
    X25519? x25519,
    Ed25519? ed25519,
    AesGcm? aesGcm,
    Hkdf? hkdf,
    int prekeyCount = 20,
  })  : _x25519 = x25519 ?? X25519(),
        _ed25519 = ed25519 ?? Ed25519(),
        _aesGcm = aesGcm ?? AesGcm.with256bits(),
        _hkdf = hkdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32),
        // ignore: prefer_initializing_formals
        _prekeyCount = prekeyCount;

  final X25519 _x25519;
  final Ed25519 _ed25519;
  final AesGcm _aesGcm;
  final Hkdf _hkdf;
  final int _prekeyCount;
  final Hmac _chainHmac = Hmac.sha256();

  final Map<String, E2eeSession> _sessions = {};
  final Map<String, _SessionOrigin> _originFor = {};

  bool hasSession(String peerId) => _sessions.containsKey(peerId);

  E2eeSession? session(String peerId) => _sessions[peerId];

  /// Every established session, so all of them can be persisted — including
  /// sessions learned from an inbound message before the chat was ever opened.
  Iterable<E2eeSession> get sessions => _sessions.values;

  /// Preloads a fetched bundle's origin so envelopes carry the right prekey
  /// ids. Sessions started via [initiateSession] record this automatically;
  /// this exists for callers that restore a session from storage.
  void rememberBundle(RemotePrekeyBundle bundle, {SimpleKeyPair? ephemeral}) {
    if (_originFor.containsKey(bundle.userId) || ephemeral == null) return;
    _originFor[bundle.userId] = _SessionOrigin(
      ephemeral: ephemeral,
      signedPrekeyId: bundle.signedPrekeyId,
      oneTimePrekeyId: bundle.oneTimePrekeyId,
    );
  }

  /// Restores a persisted session (from secure storage on app start).
  void restoreSession(E2eeSession session) {
    _sessions[session.peerId] = session;
  }

  /// Generates a fresh identity, signing key, signed prekey, and one-time
  /// prekeys. The signed prekey is signed with the identity signing key so a
  /// peer can verify it against the identity key it already pinned.
  Future<LocalKeyMaterial> generateKeyMaterial({int? startPrekeyId}) async {
    final identity = await _x25519.newKeyPair();
    final signing = await _ed25519.newKeyPair();

    final signedPrekey = await _x25519.newKeyPair();
    final signedPrekeyPublic = await signedPrekey.extractPublicKey();
    final signature = await _ed25519.sign(
      signedPrekeyPublic.bytes,
      keyPair: signing,
    );

    final base = startPrekeyId ?? DateTime.now().millisecondsSinceEpoch % 1000000;
    final prekeys = <({int keyId, SimpleKeyPair keyPair})>[];
    for (var index = 0; index < _prekeyCount; index += 1) {
      prekeys.add((keyId: base + index, keyPair: await _x25519.newKeyPair()));
    }

    return LocalKeyMaterial(
      identityKeyPair: identity,
      signingKeyPair: signing,
      signedPrekeyId: base + 100000,
      signedPrekeyKeyPair: signedPrekey,
      signedPrekeySignature: base64Encode(signature.bytes),
      prekeys: prekeys,
    );
  }

  /// Generates additional one-time prekeys for a top-up, starting at
  /// `startPrekeyId` so they do not collide with a spent batch.
  Future<List<GeneratedPrekey>> generatePrekeys({
    required int count,
    required int startPrekeyId,
  }) async {
    final generated = <GeneratedPrekey>[];
    for (var index = 0; index < count; index += 1) {
      final keyId = startPrekeyId + index;
      final keyPair = await _x25519.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      generated.add(
        GeneratedPrekey(
          keyId: keyId,
          public: PublicPrekey(keyId: keyId, publicKey: base64Encode(publicKey.bytes)),
          keyPairEntry: (keyId: keyId, keyPair: keyPair),
        ),
      );
    }
    return generated;
  }

  /// Public keys for upload, derived from [material].
  Future<PublicKeyBundle> buildPublicBundle(LocalKeyMaterial material) async {
    final identity = await material.identityKeyPair.extractPublicKey();
    final signing = await material.signingKeyPair.extractPublicKey();
    final signedPrekey = await material.signedPrekeyKeyPair.extractPublicKey();

    final prekeys = <PublicPrekey>[];
    for (final prekey in material.prekeys) {
      final publicKey = await prekey.keyPair.extractPublicKey();
      prekeys.add(
        PublicPrekey(keyId: prekey.keyId, publicKey: base64Encode(publicKey.bytes)),
      );
    }

    return PublicKeyBundle(
      identityKey: base64Encode(identity.bytes),
      signingKey: base64Encode(signing.bytes),
      signedPrekeyId: material.signedPrekeyId,
      signedPrekey: base64Encode(signedPrekey.bytes),
      signedPrekeySignature: material.signedPrekeySignature,
      prekeys: prekeys,
    );
  }

  /// Verifies that a fetched signed prekey really belongs to the recipient's
  /// claimed signing key. Rejecting a bad signature here is what stops a
  /// malicious server from substituting its own prekey and reading the chat.
  Future<bool> verifyBundle(RemotePrekeyBundle bundle) async {
    final signingKey = SimplePublicKey(
      base64Decode(bundle.signingKey),
      type: KeyPairType.ed25519,
    );
    final signature = Signature(
      base64Decode(bundle.signedPrekeySignature),
      publicKey: signingKey,
    );
    return _ed25519.verify(base64Decode(bundle.signedPrekey), signature: signature);
  }

  /// Performs X3DH as the initiator and stores the resulting session.
  Future<E2eeSession> initiateSession({
    required LocalKeyMaterial local,
    required RemotePrekeyBundle bundle,
  }) async {
    if (!await verifyBundle(bundle)) {
      throw const E2eeException('Signed prekey signature is invalid');
    }

    final ephemeral = await _x25519.newKeyPair();
    final peerIdentity = SimplePublicKey(
      base64Decode(bundle.identityKey),
      type: KeyPairType.x25519,
    );
    final peerSigned = SimplePublicKey(
      base64Decode(bundle.signedPrekey),
      type: KeyPairType.x25519,
    );

    final secrets = <Uint8List>[
      await _dh(local.identityKeyPair, peerSigned),
      await _dh(ephemeral, peerIdentity),
      await _dh(ephemeral, peerSigned),
    ];
    if (bundle.oneTimePrekey != null) {
      secrets.add(
        await _dh(
          ephemeral,
          SimplePublicKey(base64Decode(bundle.oneTimePrekey!), type: KeyPairType.x25519),
        ),
      );
    }

    final root = await _derive(secrets, _rootInfo);
    // The initiator's sending chain is the responder's receiving chain and vice
    // versa, so the two peers agree while keeping the directions independent.
    final session = E2eeSession(
      peerId: bundle.userId,
      sending: RatchetChain(key: await _deriveKey(root, _initiatorSendInfo), index: 0),
      receiving: RatchetChain(key: await _deriveKey(root, _responderSendInfo), index: 0),
    );

    _sessions[bundle.userId] = session;
    _originFor[bundle.userId] = _SessionOrigin(
      ephemeral: ephemeral,
      signedPrekeyId: bundle.signedPrekeyId,
      oneTimePrekeyId: bundle.oneTimePrekeyId,
    );
    return session;
  }

  /// Encrypts a text body for `peerId`. An existing session advances its
  /// sending chain; otherwise [bundle] is required to start one.
  Future<EncryptedEnvelope> encrypt({
    required String peerId,
    required String plaintext,
    required LocalKeyMaterial local,
    RemotePrekeyBundle? bundle,
  }) async {
    var session = _sessions[peerId];
    if (session == null) {
      if (bundle == null) {
        throw const E2eeException('No session and no prekey bundle to start one');
      }
      session = await initiateSession(local: local, bundle: bundle);
    }

    final origin = _originFor[peerId];
    // A session started by the peer (we are the responder) has no initiator
    // ephemeral of ours; the envelope then omits the X3DH initiation fields.
    final ephemeralPublic = origin == null
        ? null
        : await origin.ephemeral.extractPublicKey();

    final index = session._sending.index;
    final messageKey = await _messageKey(session._sending.key);
    final nonce = _aesGcm.newNonce();
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: messageKey,
      nonce: nonce,
    );

    session._sending.key = await _nextChainKey(session._sending.key);
    session._sending.index = index + 1;

    return EncryptedEnvelope(
      identityKey: base64Encode((await local.identityKeyPair.extractPublicKey()).bytes),
      ephemeralKey: ephemeralPublic == null ? null : base64Encode(ephemeralPublic.bytes),
      signedPrekeyId: origin?.signedPrekeyId,
      oneTimePrekeyId: origin?.oneTimePrekeyId,
      index: index,
      ciphertext: base64Encode(box.cipherText),
      nonce: base64Encode(box.nonce),
      mac: base64Encode(box.mac.bytes),
    );
  }

  /// Decrypts an inbound body.
  ///
  /// The first message of a session (no stored session yet) runs the responder
  /// side of X3DH from our private keys and the sender's ephemeral key. Later
  /// messages advance the receiving chain to the envelope's `i`, which tolerates
  /// messages we never saw (they are skipped) and a replay we already handled.
  Future<DecryptedMessage> decrypt({
    required String peerId,
    required EncryptedEnvelope envelope,
    required LocalKeyMaterial local,
    SimpleKeyPair? oneTimePrekey,
  }) async {
    var session = _sessions[peerId];

    if (session == null) {
      // Only the session-opening message carries the X3DH context needed to
      // build the responder's state; without it we cannot derive any key.
      if (envelope.ephemeralKey == null) {
        throw const E2eeException('No session and the message does not open one');
      }
      final ephemeralPublic = SimplePublicKey(
        base64Decode(envelope.ephemeralKey!),
        type: KeyPairType.x25519,
      );
      final senderIdentity = SimplePublicKey(
        base64Decode(envelope.identityKey),
        type: KeyPairType.x25519,
      );
      // Use the one-time prekey the envelope says was consumed; fall back to a
      // stored key with the same id when the caller did not pass one.
      final oneTime = oneTimePrekey ?? local.prekey(envelope.oneTimePrekeyId ?? -1);

      final secrets = <Uint8List>[
        await _dh(local.signedPrekeyKeyPair, senderIdentity),
        await _dh(local.identityKeyPair, ephemeralPublic),
        await _dh(local.signedPrekeyKeyPair, ephemeralPublic),
      ];
      if (oneTime != null) {
        secrets.add(await _dh(oneTime, ephemeralPublic));
      }

      final root = await _derive(secrets, _rootInfo);
      session = E2eeSession(
        peerId: peerId,
        // We are the responder: our sending chain is the initiator's receiving
        // chain, and our receiving chain is the initiator's sending chain.
        sending: RatchetChain(key: await _deriveKey(root, _responderSendInfo), index: 0),
        receiving: RatchetChain(key: await _deriveKey(root, _initiatorSendInfo), index: 0),
      );
      _sessions[peerId] = session;
    }

    if (envelope.index < session._receiving.index) {
      throw E2eeException(
        'Message ${envelope.index} predates the current chain position '
        '${session._receiving.index}',
      );
    }

    // Advance past any messages not delivered to this device.
    while (session._receiving.index < envelope.index) {
      session._receiving.key = await _nextChainKey(session._receiving.key);
      session._receiving.index += 1;
    }

    final messageKey = await _messageKey(session._receiving.key);
    final clear = await _aesGcm.decrypt(
      SecretBox(
        base64Decode(envelope.ciphertext),
        nonce: base64Decode(envelope.nonce),
        mac: Mac(base64Decode(envelope.mac)),
      ),
      secretKey: messageKey,
    );

    session._receiving.key = await _nextChainKey(session._receiving.key);
    session._receiving.index += 1;

    return DecryptedMessage(plaintext: utf8.decode(clear), envelope: envelope);
  }

  Future<Uint8List> _dh(SimpleKeyPair privateKey, SimplePublicKey publicKey) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: privateKey,
      remotePublicKey: publicKey,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// HKDF over the concatenated DH outputs. A fixed domain-separated `info`
  /// keeps the result bound to this protocol version.
  Future<SecretKeyData> _derive(List<Uint8List> secrets, List<int> info) async {
    final combined = Uint8List.fromList(secrets.expand((bytes) => bytes).toList());
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(combined),
      nonce: const <int>[],
      info: info,
    );
    return SecretKeyData(await key.extractBytes());
  }

  Future<SecretKeyData> _deriveKey(SecretKeyData root, List<int> info) async {
    final key = await _hkdf.deriveKey(
      secretKey: root,
      nonce: const <int>[],
      info: info,
    );
    return SecretKeyData(await key.extractBytes());
  }

  /// Chain KDF: messageKey = HMAC(chainKey, 0x01), nextChain = HMAC(chainKey, 0x02).
  /// Two distinct labels keep the message key and the next chain key unrelated.
  Future<SecretKeyData> _messageKey(SecretKeyData chainKey) async {
    final expanded = await _chainHmac.calculateMac(const [0x01], secretKey: chainKey);
    return SecretKeyData(expanded.bytes);
  }

  Future<SecretKeyData> _nextChainKey(SecretKeyData chainKey) async {
    final expanded = await _chainHmac.calculateMac(const [0x02], secretKey: chainKey);
    return SecretKeyData(expanded.bytes);
  }

  /// Serialises the private key material for secure storage.
  ///
  /// Only X25519/Ed25519 seed bytes are stored (32 bytes each), encoded to
  /// base64. The serialised blob is itself encrypted at rest by
  /// `flutter_secure_storage` (Android Keystore), so the seed is never written
  /// to plain storage.
  Future<String> exportKeyMaterial(LocalKeyMaterial material) async {
    final identity = await _seedOf(material.identityKeyPair);
    final signing = await _seedOf(material.signingKeyPair);
    final signedPrekey = await _seedOf(material.signedPrekeyKeyPair);
    final prekeys = <Map<String, dynamic>>[];
    for (final prekey in material.prekeys) {
      prekeys.add({'key_id': prekey.keyId, 'seed': base64Encode(await _seedOf(prekey.keyPair))});
    }

    return jsonEncode({
      'identity': base64Encode(identity),
      'signing': base64Encode(signing),
      'signed_prekey_id': material.signedPrekeyId,
      'signed_prekey': base64Encode(signedPrekey),
      'signed_prekey_signature': material.signedPrekeySignature,
      'prekeys': prekeys,
    });
  }

  /// Restores key material previously produced by [exportKeyMaterial].
  Future<LocalKeyMaterial> importKeyMaterial(String serialized) async {
    final json = jsonDecode(serialized) as Map<String, dynamic>;
    final prekeys = <({int keyId, SimpleKeyPair keyPair})>[];
    for (final prekey in (json['prekeys'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      prekeys.add((
        keyId: (prekey['key_id'] as num).toInt(),
        keyPair: await _x25519.newKeyPairFromSeed(base64Decode(prekey['seed'] as String)),
      ));
    }

    return LocalKeyMaterial(
      identityKeyPair: await _x25519.newKeyPairFromSeed(base64Decode(json['identity'] as String)),
      signingKeyPair: await _ed25519.newKeyPairFromSeed(base64Decode(json['signing'] as String)),
      signedPrekeyId: (json['signed_prekey_id'] as num).toInt(),
      signedPrekeyKeyPair:
          await _x25519.newKeyPairFromSeed(base64Decode(json['signed_prekey'] as String)),
      signedPrekeySignature: json['signed_prekey_signature'] as String,
      prekeys: prekeys,
    );
  }

  Future<List<int>> _seedOf(SimpleKeyPair keyPair) async =>
      Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
}

/// Rendered in place of a body that cannot be decrypted.
const String undecryptableContent = 'Unable to decrypt this message';

/// True when a body is an E2EE envelope (mirrors the server-side check).
bool isEncryptedContent(String content) => content.startsWith(e2eePrefix);

/// Decodes the envelope from a message body. Returns null for plaintext bodies
/// (Phase 1-3 clients) so the UI can fall back to showing the text as-is.
EncryptedEnvelope? decodeEnvelope(String content) {
  if (!content.startsWith(e2eePrefix)) return null;
  try {
    final decoded = jsonDecode(content.substring(e2eePrefix.length));
    if (decoded is! Map<String, dynamic>) return null;
    return EncryptedEnvelope.fromJson(decoded);
  } catch (_) {
    return null;
  }
}
