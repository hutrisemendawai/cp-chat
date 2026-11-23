import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';

import '../crypto/e2ee_service.dart';
import '../logging/app_logger.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/token_store.dart';

/// Encrypted bodies that already failed in this session, capped so a long-lived
/// app does not remember every failure forever.
const int _maxLoggedFailures = 100;

/// Coordinates end-to-end encryption for 1:1 chats.
///
/// Responsibilities:
/// - **Bootstrap:** generate key material on first run, persist the private
///   halves in secure storage, and publish only the public keys.
/// - **Prekey replenishment:** top the server's one-time prekeys back up when a
///   peer's fetch has consumed them.
/// - **Send:** encrypt a text body for a direct peer, fetching and verifying a
///   prekey bundle the first time a session is needed.
/// - **Receive:** decrypt an inbound body, falling back to the raw text for
///   plaintext (Phase 1-3) messages, and persist the ratchet state so a restart
///   does not break the chain.
///
/// Server-visible metadata (sender, timestamps, `seq`, ciphertext length) is
/// unchanged; only the message body is opaque.
class E2eeManager {
  E2eeManager({
    required TokenStore tokenStore,
    required ApiClient api,
    E2eeService? service,
    this.replenishThreshold = 5,
    this.batchSize = 20,
    AppLogger? logger,
  })  // Named parameters keep the public constructor readable while the fields
      // stay private.
      // ignore: prefer_initializing_formals
      : _tokenStore = tokenStore,
        // ignore: prefer_initializing_formals
        _api = api,
        // ignore: prefer_initializing_formals
        _logger = logger,
        _service = service ?? E2eeService();

  final TokenStore _tokenStore;
  final ApiClient _api;
  final E2eeService _service;
  final AppLogger? _logger;

  /// Publish more one-time prekeys below this count.
  final int replenishThreshold;

  /// How many prekeys a top-up publishes at once.
  final int batchSize;

  LocalKeyMaterial? _keys;
  bool _bootstrapped = false;

  /// Decrypted plaintext cache so the UI can render without awaiting on every
  /// rebuild. Keyed by `client_msg_id` (unique per message).
  final Map<String, String> _plaintext = {};

  /// Message ids whose decryption already failed and was reported, so repeated
  /// syncs do not forward the same failure again.
  final Set<String> _loggedFailures = {};

  /// Serialises inbound decryption. A live frame and a REST sync can process the
  /// same conversation at once, and advancing one receiving chain from two
  /// interleaved calls would corrupt it.
  Future<void> _decryptQueue = Future<void>.value();

  bool get isReady => _keys != null;

  Future<T> _serializeDecrypts<T>(Future<T> Function() action) {
    final result = _decryptQueue.then((_) => action());
    _decryptQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Clears in-memory session state on logout.
  ///
  /// Key material and persisted sessions stay in secure storage: they are
  /// per-device and discarding them would make existing chats unreadable. What
  /// must not survive is state belonging to the signed-out account — the
  /// decrypted plaintext cache and the peer map — so a different user signing
  /// in on this device cannot read or target the previous user's conversations.
  void reset() {
    _plaintext.clear();
    _loggedFailures.clear();
    _peerIds.clear();
    _service.reset();
    _bootstrapped = false;
    _keys = null;
  }

  /// Generates keys on first run or restores them from secure storage, then
  /// ensures the server has a publishable bundle.
  Future<void> bootstrap() async {
    if (_bootstrapped) return;

    final stored = await _tokenStore.readE2eeKeys();
    if (stored != null) {
      _keys = await _service.importKeyMaterial(stored);
      await _restoreSessions();
      // The supply may have been consumed while the app was closed.
      await _maybeReplenishOurPrekeys();
    } else {
      _keys = await _service.generateKeyMaterial();
      await _tokenStore.writeE2eeKeys(await _service.exportKeyMaterial(_keys!));
      await _publish(_keys!);
    }

    _bootstrapped = true;
  }

  /// Returns the plaintext for a message body, decrypting an envelope if needed.
  ///
  /// Plaintext bodies (old clients, media keys) are returned unchanged. A body
  /// that fails to decrypt renders a placeholder rather than throwing: a single
  /// unreadable message must not break the whole chat view.
  ///
  /// The peer is resolved from [senderId] (the frame's author, authoritative for
  /// inbound messages) and only falls back to [peerId] or the conversation map
  /// registered by the UI. Deriving it from the message means history recovered
  /// over REST decrypts even when the chat was never opened.
  Future<String> plaintextFor(
    String clientMsgId,
    String conversationId,
    String content, {
    required bool isGroup,
    String? senderId,
    String? peerId,
  }) {
    return _serializeDecrypts(
      () => _plaintextFor(
        clientMsgId,
        conversationId,
        content,
        isGroup: isGroup,
        senderId: senderId,
        peerId: peerId,
      ),
    );
  }

  Future<String> _plaintextFor(
    String clientMsgId,
    String conversationId,
    String content, {
    required bool isGroup,
    String? senderId,
    String? peerId,
  }) async {
    if (!isEncryptedContent(content)) return content;

    final cached = _plaintext[clientMsgId];
    if (cached != null) return cached;

    // Group chats have no E2EE in this phase; a ciphertext there is unreadable
    // by design rather than an error to surface.
    if (isGroup) return undecryptableContent;

    // An outgoing message synced back from the server is ciphertext, but its
    // matching receiving chain lives on the peer, so this device cannot decrypt
    // it. Leave the body untouched: the local optimistic row already holds the
    // plaintext the user typed.
    final selfId = await _tokenStore.readUserId();
    if (senderId != null && senderId == selfId) return content;

    Future<String> fail(String reason, {Object? error, Map<String, Object?>? extra}) async {
      _logFailure(
        reason,
        messageId: clientMsgId,
        conversationId: conversationId,
        senderId: senderId,
        peerId: peerId,
        error: error,
        extra: extra,
      );
      return undecryptableContent;
    }

    if (_keys == null) {
      try {
        await bootstrap();
      } catch (error) {
        debugPrint('E2EE lazy bootstrap failed: $error');
        return fail('bootstrap_failed', error: error);
      }
    }
    final keys = _keys;
    if (keys == null) return fail('no_local_keys');

    final envelope = decodeEnvelope(content);
    if (envelope == null) return fail('malformed_envelope');

    final target = peerId ?? senderId ?? await _peerIdFor(conversationId);
    if (target == null) return fail('unknown_peer');

    try {
      final decrypted = await _service.decrypt(
        peerId: target,
        envelope: envelope,
        local: keys,
      );
      _plaintext[clientMsgId] = decrypted.plaintext;
      await _persistSessions();
      return decrypted.plaintext;
    } catch (error) {
      debugPrint('E2EE decrypt failed: $error');
      return fail(
        _failureReason(error, envelope: envelope),
        error: error,
        extra: {
          'peer_id': target,
          'envelope_index': envelope.index,
          'opens_session': envelope.isInitiation,
          'one_time_prekey_id': envelope.oneTimePrekeyId,
        },
      );
    }
  }

  /// Classifies a decryption failure so the log viewer distinguishes a stale
  /// key from a tampered body.
  String _failureReason(
    Object error, {
    required EncryptedEnvelope envelope,
  }) {
    if (error is SecretBoxAuthenticationError) {
      return envelope.isInitiation
          ? 'session_key_mismatch'
          : 'session_key_mismatch_no_initiation_context';
    }
    if (error is E2eeException && error.message.contains('does not open one')) {
      return 'no_session_for_reply';
    }
    if (error is E2eeException && error.message.contains('predates')) {
      return 'chain_position_ahead';
    }
    if (error is FormatException) return 'corrupt_envelope';
    return 'decrypt_failed';
  }

  void _logFailure(
    String reason, {
    required String messageId,
    required String conversationId,
    String? senderId,
    String? peerId,
    Object? error,
    Map<String, Object?>? extra,
  }) {
    final logger = _logger;
    if (logger == null) return;

    // A conversation whose history cannot be read is retried on every sync and
    // reopen. Reporting each attempt would flood the timeline with the same
    // failure, so only the first occurrence per message is forwarded.
    if (!_loggedFailures.add(messageId)) return;
    if (_loggedFailures.length > _maxLoggedFailures) {
      _loggedFailures.remove(_loggedFailures.first);
    }

    final target = peerId ?? senderId;
    final snapshot = target == null ? null : _service.snapshot(target);
    logger.warn(
      'e2ee',
      'decrypt failed: $reason',
      meta: {
        'reason': reason,
        'message_id': messageId,
        'conversation_id': conversationId,
        'sender_id': ?senderId,
        'peer_id': ?target,
        if (error != null) 'exception': error.runtimeType.toString(),
        if (snapshot != null) 'session_present': snapshot.present,
        if (snapshot != null) 'session_initiator': snapshot.initiator,
        if (snapshot != null) 'session_confirmed': snapshot.confirmed,
        if (snapshot != null) 'session_has_origin': snapshot.hasOriginContext,
        if (snapshot != null) 'session_alternates': snapshot.alternates,
        if (snapshot != null && snapshot.present) 'receiving_index': snapshot.receivingIndex,
        if (snapshot != null && snapshot.present) 'sending_index': snapshot.sendingIndex,
        ...?extra,
      },
    );
  }

  /// Encrypts a text body for `conversationId`. Returns the original text when
  /// the conversation is a group (not covered in this phase) or keys are not
  /// ready, so sending still works before bootstrap finishes.
  ///
  /// Returns `null` when the body could not be encrypted although the
  /// conversation *is* a direct chat with a known peer and published keys.
  /// Sending plaintext there would silently downgrade the conversation, so the
  /// caller must surface the failure instead of transmitting the text.
  Future<String?> encryptForConversation({
    required String conversationId,
    required String plaintext,
    required bool isGroup,
    String? peerId,
  }) async {
    if (isGroup) return plaintext;
    if (!_bootstrapped) await bootstrap();
    final keys = _keys;
    if (keys == null) return plaintext;

    final target = peerId ?? await _peerIdFor(conversationId);
    if (target == null) return plaintext;

    RemotePrekeyBundle? bundle;
    if (!_service.hasSession(target)) {
      try {
        bundle = await _api.prekeyBundle(target);
      } on ApiException catch (error) {
        // A peer that has not published keys yet cannot receive E2EE. Send the
        // plaintext rather than blocking the conversation entirely.
        debugPrint('No prekey bundle for $target (${error.code}); sending plaintext');
        return plaintext;
      }
      // The bundle belongs to the peer, so it cannot tell us how many of *our*
      // prekeys are left. A peer opening a session consumes ours, which is the
      // signal to top up; check our own count opportunistically.
      await _maybeReplenishOurPrekeys();
    }

    try {
      final envelope = await _service.encrypt(
        peerId: target,
        plaintext: plaintext,
        local: keys,
        bundle: bundle,
      );
      await _persistSessions();
      return envelope.toContent();
    } catch (error) {
      debugPrint('E2EE encrypt failed: $error');
      _logger?.warn(
        'e2ee',
        'encrypt failed',
        meta: {
          'conversation_id': conversationId,
          'peer_id': target,
          'exception': error.runtimeType.toString(),
          'session_present': _service.hasSession(target),
        },
      );
      return null;
    }
  }

  /// Resolves the other member of a direct conversation.
  ///
  /// The peer id is registered by the chat screen once the member list is
  /// loaded (`rememberConversation`), because the local conversation row only
  /// caches the peer's *name*. Encryption is skipped until it is known.
  Future<String?> _peerIdFor(String conversationId) async {
    return _peerIds[conversationId];
  }

  /// Known peer ids per conversation, populated by [rememberConversation].
  final Map<String, String> _peerIds = {};

  /// Records the peer id for a direct conversation so encryption can target it.
  void rememberConversation(
    String conversationId, {
    required String selfId,
    required String peerId,
  }) {
    if (selfId == peerId) return;
    _peerIds[conversationId] = peerId;
  }

  Future<void> _publish(LocalKeyMaterial material) async {
    try {
      final bundle = await _service.buildPublicBundle(material);
      await _api.publishKeys(bundle);
    } catch (error) {
      debugPrint('E2EE key publish failed: $error');
    }
  }

  /// Tops up this device's one-time prekeys when the server reports a low
  /// supply.
  ///
  /// A device publishes a fixed batch and the server consumes one per session
  /// opened by a peer. Once the batch is spent, new peers fall back to the
  /// signed prekey, which still works but reuses long-term material; generating
  /// a fresh batch keeps one-time keys available. Queried from
  /// `GET /keys/me` because a *peer's* bundle reports that peer's count.
  Future<void> _maybeReplenishOurPrekeys() async {
    final keys = _keys;
    if (keys == null) return;

    try {
      final remaining = await _api.myPrekeyCount();
      if (remaining > replenishThreshold) return;
      // ...top up below.
    } on ApiException catch (error) {
      // 404 means this device has not published yet; the publish path handles
      // the first upload, so there is nothing to top up.
      if (error.statusCode == 404) return;
      debugPrint('E2EE prekey count failed: ${error.code}');
      return;
    } catch (error) {
      debugPrint('E2EE prekey count failed: $error');
      return;
    }

    try {
      final bundle = await _service.buildPublicBundle(keys);
      // Fresh ids avoid colliding with the spent batch; the server ignores a
      // re-upload of an id it already knows.
      final highest = bundle.prekeys.fold<int>(0, (max, prekey) {
        return prekey.keyId > max ? prekey.keyId : max;
      });
      final fresh = await _service.generatePrekeys(
        count: batchSize,
        startPrekeyId: highest + 1000,
      );
      await _api.addPrekeys(fresh.map((prekey) => prekey.public).toList());
      await _appendPrekeys(fresh);
    } catch (error) {
      debugPrint('E2EE prekey replenish failed: $error');
    }
  }

  Future<void> _appendPrekeys(List<GeneratedPrekey> prekeys) async {
    final keys = _keys;
    if (keys == null) return;
    final combined = [...keys.prekeys, ...prekeys.map((prekey) => prekey.keyPairEntry)];
    _keys = LocalKeyMaterial(
      identityKeyPair: keys.identityKeyPair,
      signingKeyPair: keys.signingKeyPair,
      signedPrekeyId: keys.signedPrekeyId,
      signedPrekeyKeyPair: keys.signedPrekeyKeyPair,
      signedPrekeySignature: keys.signedPrekeySignature,
      prekeys: combined,
    );
    await _tokenStore.writeE2eeKeys(await _service.exportKeyMaterial(_keys!));
  }

  /// Persists every known session, primary first, so a restart keeps both the
  /// active chain and any alternates still needed for messages in flight.
  Future<void> _persistSessions() async {
    final sessions = <String, dynamic>{};
    final peers = _service.sessions.map((session) => session.peerId).toSet();
    for (final peerId in peers) {
      sessions[peerId] = [
        for (final session in _service.sessionsFor(peerId)) session.toJson(),
      ];
    }
    await _tokenStore.writeE2eeSessions(jsonEncode(sessions));
  }

  Future<void> _restoreSessions() async {
    final raw = await _tokenStore.readE2eeSessions();
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        // Older blobs stored one session object per peer; newer ones store a
        // list ordered primary-first.
        final value = entry.value;
        final list = value is List<dynamic> ? value : <dynamic>[value];
        for (final item in list) {
          _service.restoreSession(E2eeSession.fromJson(item as Map<String, dynamic>));
        }
      }
    } catch (error) {
      debugPrint('E2EE session restore failed: $error');
      _logger?.warn(
        'e2ee',
        'session restore failed',
        meta: {'exception': error.runtimeType.toString()},
      );
    }
  }
}
