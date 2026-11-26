import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart';

import '../account/account_scope.dart';
import '../account/account_store.dart';
import '../account/legacy_migration.dart';
import '../crypto/e2ee_service.dart';
import '../logging/app_logger.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/token_store.dart';

/// Encrypted bodies that already failed in this session, capped so a long-lived
/// app does not remember every failure forever.
const int _maxLoggedFailures = 100;

/// Coordinates end-to-end encryption for 1:1 chats within a single account.
///
/// Key material and ratchet sessions live under `acct.<accountId>.*` via
/// [AccountStore] so switching accounts on the same device can never cross-load
/// or overwrite another user's identity keys.
class E2eeManager {
  E2eeManager({
    required TokenStore tokenStore,
    required ApiClient api,
    AccountStore? accountStore,
    AccountScope? scope,
    LegacyMigration? legacyMigration,
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
        _accountStore = accountStore,
        // ignore: prefer_initializing_formals
        _scope = scope,
        // ignore: prefer_initializing_formals
        _legacyMigration = legacyMigration,
        // ignore: prefer_initializing_formals
        _logger = logger,
        _service = service ?? E2eeService();

  final TokenStore _tokenStore;
  final ApiClient _api;
  final AccountStore? _accountStore;
  final AccountScope? _scope;
  final LegacyMigration? _legacyMigration;
  final E2eeService _service;
  final AppLogger? _logger;

  /// Publish more one-time prekeys below this count.
  final int replenishThreshold;

  /// How many prekeys a top-up publishes at once.
  final int batchSize;

  LocalKeyMaterial? _keys;
  bool _bootstrapped = false;

  /// True when local identity keys disagree with the server's `/keys/me`
  /// (e.g. the user signed in on another phone and rotated keys). Sending
  /// encrypted direct messages is blocked until the user explicitly chooses
  /// "Reset encryption on this device" (§3.4).
  final ValueNotifier<bool> keyMismatch = ValueNotifier<bool>(false);

  /// Latest server rotation timestamp reported by `/keys/me` or key publish,
  /// used as client-side defence in depth during historic backfill (§2.7).
  DateTime? _serverRotatedAt;
  DateTime? get serverRotatedAt => _serverRotatedAt;

  /// Latest server key epoch reported by `/keys/me`.
  int _serverKeyEpoch = 1;
  int get serverKeyEpoch => _serverKeyEpoch;

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

  /// Tracks in-flight session writes so [flush] can await them before logout
  /// closes storage (risk R-2).
  Future<void> _persistQueue = Future<void>.value();

  bool get isReady => _keys != null;
  bool get hasKeyMismatch => keyMismatch.value;
  bool get _isClosed => _scope != null && !_scope.isOpen;

  Future<String?> _readKeysBlob() =>
      _accountStore != null ? _accountStore.readE2eeKeys() : _tokenStore.readE2eeKeys();

  Future<void> _writeKeysBlob(String json) => _accountStore != null
      ? _accountStore.writeE2eeKeys(json)
      : _tokenStore.writeE2eeKeys(json);

  Future<String?> _readSessionsBlob() => _accountStore != null
      ? _accountStore.readE2eeSessions()
      : _tokenStore.readE2eeSessions();

  Future<void> _writeSessionsBlob(String json) => _accountStore != null
      ? _accountStore.writeE2eeSessions(json)
      : _tokenStore.writeE2eeSessions(json);

  Future<T> _serializeDecrypts<T>(Future<T> Function() action) {
    final result = _decryptQueue.then((_) => action());
    _decryptQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Waits for all in-flight decryptions and ratchet-session writes to finish
  /// before logout tears down the account scope.
  Future<void> flush() async {
    try {
      await _decryptQueue;
    } catch (_) {}
    try {
      await _persistQueue;
    } catch (_) {}
  }

  /// Clears in-memory session state on logout. Persisted per-account keys and
  /// sessions remain isolated under `acct.<id>.*` for R2 same-user re-login.
  void reset() {
    _plaintext.clear();
    _loggedFailures.clear();
    _peerIds.clear();
    _service.reset();
    _bootstrapped = false;
    _keys = null;
    keyMismatch.value = false;
    _serverRotatedAt = null;
  }

  /// Generates keys on first run or restores them from per-account secure
  /// storage, adopts quarantined legacy keys if `/keys/me` proves ownership,
  /// and reconciles local identity against `/keys/me` (§2.4, §3.1, §3.4).
  Future<void> bootstrap() async {
    if (_bootstrapped || _isClosed) return;

    var stored = await _readKeysBlob();

    // If this account has no keys yet, check whether ownerless legacy keys were
    // quarantined at upgrade and prove ownership against GET /keys/me.
    if (stored == null && _accountStore != null && _legacyMigration != null) {
      if (await _legacyMigration.hasQuarantinedKeys()) {
        try {
          final remote = await _api.keysMe();
          final adopted = await _legacyMigration.tryAdoptQuarantinedKeys(
            accountStore: _accountStore,
            serverIdentityKey: remote.identityKey,
          );
          if (adopted) {
            stored = await _readKeysBlob();
          }
        } catch (_) {
          // Offline or 404: cannot prove ownership now; proceed normally.
        }
      }
    }

    if (_isClosed) return;

    if (stored != null) {
      _keys = await _service.importKeyMaterial(stored);
      await _restoreSessions();
      await _reconcileWithServer();
    } else {
      _keys = await _service.generateKeyMaterial();
      if (_isClosed) return;
      await _writeKeysBlob(await _service.exportKeyMaterial(_keys!));
      await _publish(_keys!, historyWatermark: true);
    }

    _bootstrapped = true;
  }

  /// Explicit user action after a key divergence (§3.4): discards local keys
  /// and sessions, generates fresh identity keys, and publishes them with
  /// `history_watermark: true` so the server rotates the epoch and clears
  /// undecryptable direct-chat history.
  Future<void> resetEncryption() async {
    if (_isClosed) return;
    await flush();
    if (_accountStore != null) {
      await _accountStore.deleteE2ee();
    } else {
      await _tokenStore.clearE2ee();
    }
    _plaintext.clear();
    _loggedFailures.clear();
    _service.reset();
    _keys = await _service.generateKeyMaterial();
    await _writeKeysBlob(await _service.exportKeyMaterial(_keys!));
    await _publish(_keys!, historyWatermark: true);
    keyMismatch.value = false;
    _bootstrapped = true;
  }

  /// Checks local identity against `GET /api/v1/keys/me`.
  ///
  /// - Exact match: clears any mismatch flag, records server `rotated_at`, and
  ///   replenishes one-time prekeys if low.
  /// - 404 (server has no keys for us yet): publishes our local bundle.
  /// - Mismatch (different identity on server, e.g. second phone): keeps local
  ///   readable history intact and sets [keyMismatch] so outbound encrypted
  ///   sends are blocked until the user explicitly resets encryption.
  Future<void> _reconcileWithServer() async {
    final keys = _keys;
    if (keys == null || _isClosed) return;

    try {
      final remote = await _api.keysMe();
      _serverRotatedAt = remote.rotatedAt;
      _serverKeyEpoch = remote.keyEpoch;

      final localPublic = await _service.buildPublicBundle(keys);
      if (remote.identityKey.isNotEmpty &&
          remote.identityKey != localPublic.identityKey) {
        keyMismatch.value = true;
        _logger?.warn(
          'e2ee',
          'local identity key diverges from server /keys/me',
          meta: {'server_epoch': remote.keyEpoch},
        );
        return;
      }

      keyMismatch.value = false;
      if (remote.oneTimePrekeys <= replenishThreshold) {
        await _replenishPrekeys(keys);
      }
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        await _publish(keys, historyWatermark: true);
        return;
      }
      debugPrint('E2EE key status check failed: ${error.code}');
    } catch (error) {
      // Fallback for older test fakes that only override `myPrekeyCount`.
      debugPrint('E2EE keysMe check failed: $error');
      await _maybeReplenishOurPrekeys();
    }
  }

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
    if (_isClosed) return undecryptableContent;
    if (!isEncryptedContent(content)) return content;

    final cached = _plaintext[clientMsgId];
    if (cached != null) return cached;

    if (isGroup) return undecryptableContent;

    // Resolve selfId from the bound AccountScope first so a concurrent account
    // switch can never compare against another user's id.
    final selfId = _scope?.userId ?? await _tokenStore.readUserId();
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
    if (_isClosed) return undecryptableContent;
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
      if (_isClosed) return undecryptableContent;
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

  Future<String?> encryptForConversation({
    required String conversationId,
    required String plaintext,
    required bool isGroup,
    String? peerId,
  }) async {
    if (isGroup) return plaintext;
    if (_isClosed) return null;
    if (!_bootstrapped) await bootstrap();
    if (_isClosed) return null;

    // Key divergence blocks sending encrypted messages until resolved (§3.4).
    if (keyMismatch.value) return null;

    final keys = _keys;
    if (keys == null) return plaintext;

    final target = peerId ?? await _peerIdFor(conversationId);
    if (target == null) return plaintext;

    RemotePrekeyBundle? bundle;
    if (!_service.hasSession(target)) {
      try {
        bundle = await _api.prekeyBundle(target);
      } on ApiException catch (error) {
        debugPrint('No prekey bundle for $target (${error.code}); sending plaintext');
        return plaintext;
      }
      await _maybeReplenishOurPrekeys();
    }

    try {
      final envelope = await _service.encrypt(
        peerId: target,
        plaintext: plaintext,
        local: keys,
        bundle: bundle,
      );
      if (_isClosed) return null;
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

  Future<String?> _peerIdFor(String conversationId) async {
    return _peerIds[conversationId];
  }

  final Map<String, String> _peerIds = {};

  void rememberConversation(
    String conversationId, {
    required String selfId,
    required String peerId,
  }) {
    if (selfId == peerId) return;
    _peerIds[conversationId] = peerId;
  }

  Future<void> _publish(
    LocalKeyMaterial material, {
    bool historyWatermark = true,
  }) async {
    try {
      final bundle = await _service.buildPublicBundle(material);
      await _api.publishKeys(bundle, historyWatermark: historyWatermark);
      _serverRotatedAt = DateTime.now().toUtc();
    } catch (error) {
      debugPrint('E2EE key publish failed: $error');
    }
  }

  Future<void> _maybeReplenishOurPrekeys() async {
    final keys = _keys;
    if (keys == null || _isClosed) return;

    try {
      final remaining = await _api.myPrekeyCount();
      if (remaining > replenishThreshold) return;
    } on ApiException catch (error) {
      if (error.statusCode == 404) return;
      debugPrint('E2EE prekey count failed: ${error.code}');
      return;
    } catch (error) {
      debugPrint('E2EE prekey count failed: $error');
      return;
    }

    await _replenishPrekeys(keys);
  }

  Future<void> _replenishPrekeys(LocalKeyMaterial keys) async {
    if (_isClosed) return;
    try {
      final bundle = await _service.buildPublicBundle(keys);
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
    if (keys == null || _isClosed) return;
    final combined = [...keys.prekeys, ...prekeys.map((prekey) => prekey.keyPairEntry)];
    _keys = LocalKeyMaterial(
      identityKeyPair: keys.identityKeyPair,
      signingKeyPair: keys.signingKeyPair,
      signedPrekeyId: keys.signedPrekeyId,
      signedPrekeyKeyPair: keys.signedPrekeyKeyPair,
      signedPrekeySignature: keys.signedPrekeySignature,
      prekeys: combined,
    );
    await _writeKeysBlob(await _service.exportKeyMaterial(_keys!));
  }

  Future<void> _persistSessions() {
    if (_isClosed) return Future<void>.value();
    final run = _persistQueue.then((_) async {
      if (_isClosed) return;
      final sessions = <String, dynamic>{};
      final peers = _service.sessions.map((session) => session.peerId).toSet();
      for (final peerId in peers) {
        sessions[peerId] = [
          for (final session in _service.sessionsFor(peerId)) session.toJson(),
        ];
      }
      await _writeSessionsBlob(jsonEncode(sessions));
    });
    _persistQueue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _restoreSessions() async {
    final raw = await _readSessionsBlob();
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
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
