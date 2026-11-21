import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../crypto/e2ee_service.dart' show isEncryptedContent;
import '../notifications/crash_reporter.dart';
import '../database/chat_dao.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/token_store.dart';

/// Owns the realtime connection and keeps the local mirror consistent.
///
/// Responsibilities, per `docs/ws-protocol.md`:
/// - authenticate the upgrade and reconnect with exponential backoff + jitter;
/// - on every (re)connect, sync each conversation after its local cursor
///   *before* accepting live frames, so gaps can never be missed;
/// - flush the outbox and retry unacknowledged sends;
/// - persist `message` frames and reconcile optimistic rows by `client_msg_id`;
/// - report `delivered` automatically for persisted messages.
class ChatSocket {
  ChatSocket(
    this._dao,
    this._api,
    this._tokenStore, {
    this.heartbeatInterval = const Duration(seconds: 25),
    this.sendTimeout = const Duration(seconds: 10),
    this.decrypt,
  });

  final ChatDao _dao;
  final ApiClient _api;
  final TokenStore _tokenStore;
  final Duration heartbeatInterval;
  final Duration sendTimeout;

  /// Decrypts an inbound E2EE body before it is persisted, so the local mirror
  /// (and therefore the UI) only ever holds plaintext. Returning null leaves the
  /// original content untouched, which is what a group or plaintext message
  /// does.
  final Future<String?> Function(String conversationId, String clientMsgId, String content)?
      decrypt;

  final Random _random = Random();

  final Map<String, Timer> _sendTimers = {};
  final Set<String> _awaitingAck = {};

  /// Live `presence` frames for users who share a conversation with us.
  /// Broadcast so several chat headers can listen at once; the latest snapshot
  /// is still fetched over REST when a chat opens.
  final StreamController<Presence> _presenceController =
      StreamController<Presence>.broadcast();

  Stream<Presence> get presenceEvents => _presenceController.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  Timer? _outboxTimer;
  int _attempt = 0;
  bool _disposed = false;
  bool _syncing = false;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_disposed || _channel != null) return;
    _reconnect?.cancel();

    final token = await _tokenStore.readAccessToken();
    if (token == null) return;

    try {
      final channel = WebSocketChannel.connect(AppConfig.wsUri(token));
      await channel.ready;
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onDone: _onDisconnected,
        onError: (Object error) {
          debugPrint('ChatSocket error: $error');
          _onDisconnected();
        },
        cancelOnError: true,
      );
      _attempt = 0;
      _startHeartbeat();

      // Recover anything missed while offline before accepting live traffic.
      await syncAll();
      await flushOutbox();
      _startOutboxRetry();
    } catch (error) {
      debugPrint('ChatSocket connect failed: $error');
      _onDisconnected();
    }
  }

  /// Pulls every conversation forward from its local `last_seq`.
  Future<void> syncAll({String? selfId}) async {
    if (_syncing) return;
    _syncing = true;
    try {
      final user = selfId ?? await _tokenStore.readUserId();
      final conversations = await _api.conversations(limit: 100);
      await _dao.upsertConversations(conversations, selfId: user);

      for (final conversation in conversations) {
        final cursor = await _dao.localMaxSeq(conversation.id);
        if (conversation.lastSeq <= cursor) continue;
        await _syncConversation(conversation.id, cursor);
      }
    } catch (error) {
      debugPrint('ChatSocket sync failed: $error');
    } finally {
      _syncing = false;
    }
  }

  /// Fetches missed messages for one conversation, following `latest_seq` until
  /// the local cursor catches up.
  Future<void> _syncConversation(String conversationId, int afterSeq) async {
    var cursor = afterSeq;
    for (var page = 0; page < 50; page += 1) {
      final result = await _api.sync(conversationId, afterSeq: cursor);
      if (result.messages.isEmpty) return;
      await _dao.upsertServerMessages(result.messages);
      cursor = result.messages.last.seq;
      if (cursor >= result.latestSeq) return;
    }
  }

  /// Adds a message to the outbox and sends it if the socket is up.
  ///
  /// [content] is stored for display; [wireContent] is what goes on the wire
  /// and defaults to the same value. A retry always resends [wireContent], so an
  /// encrypted body is never re-encrypted (which would advance the ratchet).
  Future<void> send({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required String content,
    String? wireContent,
    String type = 'text',
  }) async {
    await _dao.enqueueOutgoing(
      clientMsgId: clientMsgId,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      content: content,
      wireContent: wireContent,
      createdAt: DateTime.now().toUtc(),
    );
    _writeSend(conversationId, clientMsgId, wireContent ?? content, type);
  }

  /// Retries a failed or pending outbox entry with the same `client_msg_id`.
  Future<void> retry(String conversationId, String clientMsgId) async {
    final pending = await _dao.pendingOutbox();
    final entry = pending.where((item) => item.clientMsgId == clientMsgId).firstOrNull;
    if (entry == null) return;
    _writeSend(conversationId, clientMsgId, entry.wireContent ?? entry.content, entry.type);
  }

  Future<void> discard(String clientMsgId) => _dao.deleteMessage(clientMsgId);

  /// Reports `delivered` for a message the client has persisted.
  void acknowledgeDelivered(String conversationId, int seq) {
    _write({
      'type': 'ack',
      'conversation_id': conversationId,
      'seq': seq,
      'status': 'delivered',
    });
  }

  /// Reports `read` up to `seq`; the server clamps it monotonically.
  Future<void> acknowledgeRead(String conversationId, int seq) async {
    await _dao.setReadCursor(conversationId, seq);
    await _dao.clearUnread(conversationId);
    _write({
      'type': 'ack',
      'conversation_id': conversationId,
      'seq': seq,
      'status': 'read',
    });
  }

  /// Re-sends every outbox entry. Called on connect and by the retry timer.
  Future<void> flushOutbox() async {
    final pending = await _dao.pendingOutbox();
    for (final entry in pending) {
      _writeSend(
        entry.conversationId,
        entry.clientMsgId,
        entry.wireContent ?? entry.content,
        entry.type,
      );
      await _dao.recordAttempt(entry.clientMsgId);
    }
  }

  void _writeSend(String conversationId, String clientMsgId, String content, String type) {
    final sent = _write({
      'type': 'send',
      'conversation_id': conversationId,
      'client_msg_id': clientMsgId,
      'msg_type': type,
      'content': content,
    });
    if (!sent) return;

    _awaitingAck.add(clientMsgId);
    _sendTimers[clientMsgId]?.cancel();
    _sendTimers[clientMsgId] = Timer(sendTimeout, () {
      _sendTimers.remove(clientMsgId);
      if (_awaitingAck.remove(clientMsgId)) {
        // No ACK in time: leave the entry queued for the retry loop.
        unawaited(_dao.markFailed(clientMsgId));
      }
    });
  }

  bool _write(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(jsonEncode(event));
      return true;
    } catch (error) {
      debugPrint('ChatSocket write failed: $error');
      _onDisconnected();
      return false;
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return;
      decoded = value;
    } catch (error) {
      debugPrint('ChatSocket dropped malformed frame: $error');
      return;
    }

    switch (decoded['type']) {
      case 'pong':
        return;
      case 'message':
        unawaited(_handleMessage(decoded));
      case 'status':
        unawaited(_handleStatus(decoded));
      case 'read_receipt':
        unawaited(_handleReadReceipt(decoded));
      case 'read_state':
        unawaited(_handleReadState(decoded));
      case 'presence':
        _handlePresence(decoded);
      case 'conversation_updated':
        unawaited(_handleConversationUpdated(decoded));
      case 'error':
        debugPrint('ChatSocket server error: ${decoded['code']}');
      default:
        // Unknown server events are ignored by contract.
        return;
    }
  }

  Future<void> _handleMessage(Map<String, dynamic> frame) async {
    try {
      var message = Message.fromJson({
        'id': frame['message_id'],
        'conversation_id': frame['conversation_id'],
        'seq': frame['seq'],
        'sender_id': frame['sender_id'],
        'client_msg_id': frame['client_msg_id'],
        'type': frame['msg_type'],
        'content': frame['content'],
        'created_at': frame['created_at'],
      });

      // A gap means frames were missed (e.g. a socket hiccup). Sync first so the
      // local history stays ordered by seq.
      final localMax = await _dao.localMaxSeq(message.conversationId);
      if (message.seq > localMax + 1) {
        await _syncConversation(message.conversationId, localMax);
      }

      // Persist plaintext: decrypt an E2EE body before it reaches the mirror so
      // every reader of the local row (bubbles, previews, search) sees text.
      final plaintext = await _decryptForStorage(message);
      if (plaintext != null) {
        message = Message(
          id: message.id,
          conversationId: message.conversationId,
          seq: message.seq,
          senderId: message.senderId,
          clientMsgId: message.clientMsgId,
          type: message.type,
          content: plaintext,
          createdAt: message.createdAt,
        );
      }

      await _dao.upsertServerMessage(message);
      acknowledgeDelivered(message.conversationId, message.seq);
    } catch (error) {
      debugPrint('ChatSocket failed to persist message: $error');
    }
  }

  /// Decrypts a body for storage. A failed decrypt keeps the ciphertext rather
  /// than dropping the message, so it can be retried after keys are available.
  Future<String?> _decryptForStorage(Message message) async {
    final decryptor = decrypt;
    if (decryptor == null || message.type != 'text') return null;
    if (!isEncryptedContent(message.content)) return null;
    try {
      return await decryptor(message.conversationId, message.clientMsgId, message.content);
    } catch (error, stack) {
      debugPrint('ChatSocket could not decrypt message: $error');
      CrashReporter.record(error, stack, reason: 'e2ee_decrypt_failed');
      return null;
    }
  }

  Future<void> _handleStatus(Map<String, dynamic> frame) async {
    final clientMsgId = frame['client_msg_id'];
    final status = frame['status'];
    if (clientMsgId is! String || status is! String) return;

    if (status == 'sent') {
      _awaitingAck.remove(clientMsgId);
      _sendTimers.remove(clientMsgId)?.cancel();
    }
    await _dao.applyStatus(clientMsgId, status);
  }

  /// A [ReadReceipt] means every message this user sent up to `seq` has been
  /// read by that many members, not only the message at `seq`.
  Future<void> _handleReadReceipt(Map<String, dynamic> frame) async {
    final conversationId = frame['conversation_id'];
    final seq = frame['seq'];
    final readCount = frame['read_count'];
    final memberCount = frame['member_count'];
    if (conversationId is! String || seq is! num || readCount is! num || memberCount is! num) {
      return;
    }

    final selfId = await _tokenStore.readUserId();
    if (selfId == null) return;
    await _dao.applyReadReceipt(
      conversationId: conversationId,
      selfId: selfId,
      upToSeq: seq.toInt(),
      readCount: readCount.toInt(),
      memberCount: memberCount.toInt(),
    );
  }

  /// A membership/name/avatar change happened elsewhere; refresh the metadata
  /// and catch up on any messages, or drop the conversation if this user was
  /// removed.
  Future<void> _handleConversationUpdated(Map<String, dynamic> frame) async {
    final conversationId = frame['conversation_id'];
    if (conversationId is! String) return;

    final selfId = await _tokenStore.readUserId();
    try {
      final conversation = await _api.conversation(conversationId);
      await _dao.upsertConversation(conversation, selfId: selfId);
      final cursor = await _dao.localMaxSeq(conversationId);
      if (conversation.lastSeq > cursor) {
        await _syncConversation(conversationId, cursor);
      }
    } on ApiException catch (error) {
      if (error.statusCode == 403 || error.statusCode == 404) {
        await _dao.deleteConversation(conversationId);
      }
    } catch (error) {
      debugPrint('ChatSocket refresh conversation failed: $error');
    }
  }

  /// Another of this user's devices advanced the read cursor. Move the local
  /// cursor forward so the unread badge clears without a manual sync.
  Future<void> _handleReadState(Map<String, dynamic> frame) async {
    final conversationId = frame['conversation_id'];
    final seq = frame['seq'];
    if (conversationId is! String || seq is! num) return;

    await _dao.setReadCursor(conversationId, seq.toInt());
    await _dao.clearUnread(conversationId);
  }

  void _handlePresence(Map<String, dynamic> frame) {
    final userId = frame['user_id'];
    final online = frame['online'];
    if (userId is! String || online is! bool) return;

    _presenceController.add(
      Presence.fromJson({
        'user_id': userId,
        'online': online,
        'last_seen_at': frame['last_seen_at'],
      }),
    );
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (!_write({'type': 'ping'})) _onDisconnected();
    });
  }

  void _startOutboxRetry() {
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (isConnected) unawaited(flushOutbox());
    });
  }

  void _onDisconnected() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    for (final timer in _sendTimers.values) {
      timer.cancel();
    }
    _sendTimers.clear();
    _awaitingAck.clear();
    if (_disposed) return;

    final exponential = min(30, pow(2, _attempt).toInt());
    final jitterMs = _random.nextInt(1000);
    _attempt += 1;
    _reconnect?.cancel();
    _reconnect = Timer(
      Duration(seconds: exponential, milliseconds: jitterMs),
      connect,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    _outboxTimer?.cancel();
    for (final timer in _sendTimers.values) {
      timer.cancel();
    }
    await _presenceController.close();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }
}
