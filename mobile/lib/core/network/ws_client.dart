import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../account/account_scope.dart';
import '../config/app_config.dart';
import '../crypto/e2ee_service.dart'
    show isEncryptedContent, undecryptableContent;
import '../logging/app_logger.dart';
import '../notifications/crash_reporter.dart';
import '../database/chat_dao.dart';
import '../models/models.dart';
import '../network/api_client.dart';
import '../storage/token_store.dart';

/// Lifecycle of the realtime connection, surfaced to the UI.
enum SocketState { disconnected, connecting, connected }

/// A snapshot of the connection plus the last failure, for a status banner.
@immutable
class SocketStatus {
  const SocketStatus(this.state, [this.lastError]);

  const SocketStatus.disconnected([String? error])
    : this(SocketState.disconnected, error);

  final SocketState state;
  final String? lastError;

  bool get isConnected => state == SocketState.connected;
  bool get isConnecting => state == SocketState.connecting;

  @override
  bool operator ==(Object other) =>
      other is SocketStatus &&
      other.state == state &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(state, lastError);
}

/// Owns the realtime connection and keeps the local mirror consistent.
///
/// Bound to an optional [AccountScope]: every async continuation checks
/// `_scopeClosed` so late frames, sync pages, or outbox flushes from a signing-
/// out account can never write to another account's database (§2.2, §3.2).
class ChatSocket {
  ChatSocket(
    this._dao,
    this._api,
    this._tokenStore, {
    this.heartbeatInterval = const Duration(seconds: 25),
    this.sendTimeout = const Duration(seconds: 10),
    this.decrypt,
    this.logger,
    this.scope,
    this.serverRotatedAt,
    this.beforeSync,
  });

  final ChatDao _dao;
  final ApiClient _api;
  final TokenStore _tokenStore;
  final AccountScope? scope;
  final Duration heartbeatInterval;
  final Duration sendTimeout;
  final AppLogger? logger;

  /// Latest server key-rotation timestamp (`/keys/me.rotated_at`), used as
  /// client-side defence in depth during historic backfill (§2.7).
  final DateTime? Function()? serverRotatedAt;

  /// Optional hook run immediately before `syncAll` (used to flush offline
  /// queued server history clears before pulling messages).
  final Future<void> Function()? beforeSync;

  final Future<String?> Function(
    String conversationId,
    String clientMsgId,
    String senderId,
    String content, {
    required bool isGroup,
  })?
  decrypt;

  /// Fired for a live inbound `message` frame once it has been decrypted and
  /// persisted. Notification code hooks this; the REST sync and history
  /// pagination paths deliberately do not call it, so bulk catch-up never
  /// raises a banner.
  void Function(Message message, {String? senderName})? onIncomingMessage;

  final Random _random = Random();

  final Map<String, Timer> _sendTimers = {};
  final Set<String> _awaitingAck = {};

  final StreamController<Presence> _presenceController =
      StreamController<Presence>.broadcast();

  Stream<Presence> get presenceEvents => _presenceController.stream;

  /// The current connection status, reactive so a screen can show a banner.
  final ValueNotifier<SocketStatus> connection = ValueNotifier<SocketStatus>(
    const SocketStatus.disconnected(),
  );

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  Timer? _outboxTimer;
  int _attempt = 0;
  int _disconnectToken = 0;
  bool _disposed = false;
  bool _syncing = false;
  bool _connecting = false;
  Completer<void>? _syncBarrier;
  final Map<String, Future<void>> _messageQueues = {};
  final Map<String, (String, int)> _recoveryCursors = {};

  bool get isConnected => _channel != null;
  bool get _scopeClosed => _disposed || (scope != null && !scope!.isOpen);

  Future<String?> _selfId() async =>
      scope?.userId ?? await _tokenStore.readUserId();

  Future<void> connect() async {
    if (_scopeClosed || _channel != null || _connecting) return;
    final tokenBefore = _disconnectToken;
    _reconnect?.cancel();
    _connecting = true;
    connection.value = const SocketStatus(SocketState.connecting);

    try {
      final token = await _api.ensureFreshAccessToken();
      if (_scopeClosed || tokenBefore != _disconnectToken) return;
      if (token == null) {
        connection.value = const SocketStatus.disconnected('Not signed in');
        return;
      }
      try {
        await _open(token, tokenBefore);
      } catch (error) {
        if (_scopeClosed || tokenBefore != _disconnectToken) return;
        if (!_authFailure(error) || !await _api.refreshAccessToken()) rethrow;
        if (_scopeClosed || tokenBefore != _disconnectToken) return;
        final rotated = await _tokenStore.readAccessToken();
        if (rotated == null) rethrow;
        await _open(rotated, tokenBefore);
      }
    } catch (error) {
      if (_scopeClosed || tokenBefore != _disconnectToken) return;
      debugPrint('ChatSocket connect failed: $error');
      logger?.warn('ws', 'connect failed', meta: {'error': error.toString()});
      _onDisconnected(error);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _open(String token, int disconnectToken) async {
    final channel = WebSocketChannel.connect(AppConfig.wsUri(token));
    await channel.ready;
    if (_scopeClosed || disconnectToken != _disconnectToken) {
      await channel.sink.close();
      return;
    }

    _channel = channel;
    _subscription = channel.stream.listen(
      _onData,
      onDone: _onDisconnected,
      onError: (Object error) {
        debugPrint('ChatSocket error: $error');
        _onDisconnected(error);
      },
      cancelOnError: true,
    );
    _attempt = 0;
    connection.value = const SocketStatus(SocketState.connected);
    logger?.info('ws', 'connected');
    _startHeartbeat();

    // Recover anything missed while offline before accepting live traffic.
    await syncAll();
    if (_scopeClosed || disconnectToken != _disconnectToken) return;
    await flushOutbox();
    if (_scopeClosed || disconnectToken != _disconnectToken) return;
    _startOutboxRetry();
  }

  bool _authFailure(Object error) {
    final text = error.toString();
    return text.contains('401') ||
        text.contains('403') ||
        text.contains('Unauthorized');
  }

  /// Closes the connection, stops every timer, invalidates in-flight syncs,
  /// and awaits any in-flight sync barrier (bounded) so local DB teardown can
  /// proceed cleanly.
  Future<void> disconnect() async {
    _disconnectToken += 1;
    _reconnect?.cancel();
    _reconnect = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    for (final timer in _sendTimers.values) {
      timer.cancel();
    }
    _sendTimers.clear();
    _awaitingAck.clear();
    _recoveryCursors.clear();
    _attempt = 0;
    _connecting = false;

    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (!_disposed) {
      connection.value = const SocketStatus.disconnected();
    }

    if (subscription != null) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 2));
      } catch (error) {
        debugPrint('ChatSocket subscription cancel failed: $error');
      }
    }
    if (channel != null) {
      try {
        await channel.sink.close().timeout(const Duration(seconds: 2));
      } catch (error) {
        debugPrint('ChatSocket channel close failed: $error');
      }
    }

    // Wait briefly for any in-flight sync pass to observe cancellation and exit.
    final barrier = _syncBarrier;
    if (barrier != null && !barrier.isCompleted) {
      try {
        await barrier.future.timeout(const Duration(seconds: 2));
      } catch (_) {
        // Bounded: never stall logout.
      }
    }
    _syncing = false;
  }

  /// Pulls every conversation forward from `max(localMaxSeq, clearedSeq)`.
  Future<void> syncAll({String? selfId}) async {
    if (_scopeClosed) return;
    if (_syncing) {
      await _syncBarrier?.future;
      return;
    }
    final tokenBefore = _disconnectToken;
    _syncing = true;
    final barrier = Completer<void>();
    _syncBarrier = barrier;
    try {
      // Flush any offline-queued server clears before pulling history (§3.5).
      final hook = beforeSync;
      if (hook != null) {
        try {
          await hook();
        } catch (error) {
          debugPrint('ChatSocket beforeSync hook failed: $error');
        }
      }
      if (_scopeClosed || tokenBefore != _disconnectToken) return;

      final user = selfId ?? await _selfId();
      final conversations = await _api.conversations(limit: 100);
      if (_scopeClosed || tokenBefore != _disconnectToken) return;

      await _dao.upsertConversations(conversations, selfId: user);

      for (final conversation in conversations) {
        if (_scopeClosed || tokenBefore != _disconnectToken) return;
        try {
          await _serializeMessages(
            conversation.id,
            () => _syncSummary(conversation, disconnectToken: tokenBefore),
          );
        } catch (error) {
          debugPrint('ChatSocket conversation sync failed: $error');
        }
      }
    } catch (error) {
      debugPrint('ChatSocket sync failed: $error');
    } finally {
      _syncing = false;
      _syncBarrier = null;
      if (!barrier.isCompleted) barrier.complete();
    }
  }

  Future<void> _serializeMessages(
    String conversationId,
    Future<void> Function() action,
  ) {
    final previous = _messageQueues[conversationId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _messageQueues[conversationId] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_messageQueues[conversationId], tail)) {
          _messageQueues.remove(conversationId);
        }
      }),
    );
    return result;
  }

  Future<void> _syncSummary(
    Conversation conversation, {
    required int disconnectToken,
  }) async {
    if (_scopeClosed || disconnectToken != _disconnectToken) return;
    final cursor = await _dao.effectiveCursor(conversation.id);
    final clearedFloor = await _dao.clearedSeqFor(conversation.id);
    final latest = conversation.lastMessage;
    if (latest != null &&
        latest.conversationId == conversation.id &&
        latest.seq > clearedFloor &&
        latest.seq > 0 &&
        latest.seq <= cursor &&
        latest.type == 'text' &&
        isEncryptedContent(latest.content) &&
        latest.senderId != await _selfId() &&
        !await _alreadyReadable(latest)) {
      if (_scopeClosed || disconnectToken != _disconnectToken) return;
      final result = await _api.sync(
        conversation.id,
        afterSeq: latest.seq - 1,
        limit: 1,
      );
      if (_scopeClosed || disconnectToken != _disconnectToken) return;
      if (result.clearedSeq > 0) {
        await _dao.applyClearedSeq(conversation.id, result.clearedSeq);
      }
      if (result.messages.length == 1) {
        final candidate = result.messages.single;
        if (candidate.conversationId == conversation.id &&
            candidate.seq == latest.seq &&
            candidate.clientMsgId == latest.clientMsgId &&
            candidate.id == latest.id &&
            candidate.senderId == latest.senderId &&
            candidate.type == latest.type &&
            candidate.content == latest.content) {
          final previous = _recoveryCursors[conversation.id];
          final start = max(
            clearedFloor,
            previous?.$1 == latest.clientMsgId ? previous!.$2 : 0,
          );
          if (start >= latest.seq) {
            await _persistServerMessage(candidate, isHistoricBackfill: true);
          } else {
            final recovered = await _syncConversation(
              conversation.id,
              start,
              throughSeq: latest.seq,
              disconnectToken: disconnectToken,
            );
            _recoveryCursors[conversation.id] = (latest.clientMsgId, recovered);
          }
        }
      }
    }
    if (_scopeClosed || disconnectToken != _disconnectToken) return;
    if (conversation.lastSeq > cursor) {
      await _syncConversation(
        conversation.id,
        cursor,
        disconnectToken: disconnectToken,
      );
    }
  }

  Future<int> _syncConversation(
    String conversationId,
    int afterSeq, {
    int? throughSeq,
    int? disconnectToken,
  }) async {
    var cursor = afterSeq;
    var droppedPreRotation = 0;
    DateTime? droppedAt;
    for (var page = 0; page < 50; page += 1) {
      if (_scopeClosed) return cursor;
      if (disconnectToken != null && disconnectToken != _disconnectToken) {
        return cursor;
      }
      if (throughSeq != null && cursor >= throughSeq) return cursor;
      final limit = throughSeq == null ? 200 : min(200, throughSeq - cursor);
      final result = await _api.sync(conversationId, afterSeq: cursor, limit: limit);
      if (_scopeClosed) return cursor;
      if (disconnectToken != null && disconnectToken != _disconnectToken) {
        return cursor;
      }

      if (result.clearedSeq > 0) {
        await _dao.applyClearedSeq(conversationId, result.clearedSeq);
        if (cursor < result.clearedSeq) {
          cursor = result.clearedSeq;
        }
      }

      if (result.messages.isEmpty) break;
      for (final message in result.messages) {
        if (_scopeClosed) return cursor;
        if (message.conversationId != conversationId ||
            message.seq != cursor + 1) {
          throw StateError('Invalid sync message ordering');
        }
        final stored = await _persistServerMessage(
          message,
          isHistoricBackfill: true,
        );
        if (!stored) {
          droppedPreRotation += 1;
          droppedAt = message.createdAt;
        }
        cursor = message.seq;
      }
      if (cursor >= result.latestSeq) break;
    }

    if (droppedPreRotation > 0 && !_scopeClosed) {
      await _dao.upsertSystemNotice(
        clientMsgId: 'system:pre-rotation:$conversationId',
        conversationId: conversationId,
        content: 'Encrypted history is not restored on a new or cleared device.',
        createdAt: droppedAt ?? DateTime.now().toUtc(),
      );
    }

    return cursor;
  }

  Future<void> storeServerMessages(List<Message> messages) async {
    if (_scopeClosed) return;
    final barrier = _syncBarrier;
    if (barrier != null) await barrier.future;
    if (_scopeClosed) return;

    final groups = <String, List<Message>>{};
    for (final message in messages) {
      (groups[message.conversationId] ??= []).add(message);
    }
    for (final entry in groups.entries) {
      if (_scopeClosed) return;
      entry.value.sort((a, b) => a.seq.compareTo(b.seq));
      await _serializeMessages(entry.key, () async {
        if (_scopeClosed) return;
        var blocked = false;
        for (final message in entry.value) {
          if (_scopeClosed) return;
          final cursor = await _dao.effectiveCursor(entry.key);
          if (!blocked && message.seq > cursor + 1) {
            var synced = cursor;
            try {
              synced = await _syncConversation(entry.key, cursor);
            } catch (error) {
              debugPrint('ChatSocket history sync failed: $error');
            }
            blocked = synced < message.seq - 1;
          }
          if (_scopeClosed) return;
          if (blocked && isEncryptedContent(message.content)) {
            await _dao.upsertServerMessage(Message(
              id: message.id,
              conversationId: message.conversationId,
              seq: message.seq,
              senderId: message.senderId,
              clientMsgId: message.clientMsgId,
              type: message.type,
              content: undecryptableContent,
              createdAt: message.createdAt,
            ));
          } else {
            await _persistServerMessage(message, isHistoricBackfill: true);
          }
        }
      });
    }
  }

  Future<bool> _alreadyReadable(Message message) async {
    final existing = await _dao.message(message.clientMsgId);
    if (existing == null ||
        existing.conversationId != message.conversationId ||
        (existing.seq != null && existing.seq != message.seq)) {
      return false;
    }
    return !isEncryptedContent(existing.content) &&
        existing.content != undecryptableContent;
  }

  Future<void> send({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required String content,
    String? wireContent,
    String type = 'text',
  }) async {
    if (_scopeClosed) return;
    await _dao.enqueueOutgoing(
      clientMsgId: clientMsgId,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      content: content,
      wireContent: wireContent,
      createdAt: DateTime.now().toUtc(),
    );
    if (!_writeSend(
      conversationId,
      clientMsgId,
      wireContent ?? content,
      type,
    )) {
      unawaited(connect());
    }
  }

  Future<void> retry(String conversationId, String clientMsgId) async {
    if (_scopeClosed) return;
    final pending = await _dao.pendingOutbox();
    final entry = pending
        .where((item) => item.clientMsgId == clientMsgId)
        .firstOrNull;
    if (entry == null) return;

    await _dao.markPending(clientMsgId);
    final sent = _writeSend(
      conversationId,
      clientMsgId,
      entry.wireContent ?? entry.content,
      entry.type,
    );
    if (!sent) unawaited(connect());
  }

  Future<void> discard(String clientMsgId) => _dao.deleteMessage(clientMsgId);

  void acknowledgeDelivered(String conversationId, int seq) {
    if (_scopeClosed) return;
    _write({
      'type': 'ack',
      'conversation_id': conversationId,
      'seq': seq,
      'status': 'delivered',
    });
  }

  Future<void> acknowledgeRead(String conversationId, int seq) async {
    if (_scopeClosed) return;
    await _dao.setReadCursor(conversationId, seq);
    await _dao.clearUnread(conversationId);
    _write({
      'type': 'ack',
      'conversation_id': conversationId,
      'seq': seq,
      'status': 'read',
    });
  }

  Future<void> flushOutbox() async {
    if (_scopeClosed || !isConnected) return;
    final pending = await _dao.pendingOutbox();
    for (final entry in pending) {
      if (_scopeClosed || !isConnected) return;
      if (_writeSend(
        entry.conversationId,
        entry.clientMsgId,
        entry.wireContent ?? entry.content,
        entry.type,
      )) {
        await _dao.recordAttempt(entry.clientMsgId);
      }
    }
  }

  bool _writeSend(
    String conversationId,
    String clientMsgId,
    String content,
    String type,
  ) {
    if (_scopeClosed) return false;
    final sent = _write({
      'type': 'send',
      'conversation_id': conversationId,
      'client_msg_id': clientMsgId,
      'msg_type': type,
      'content': content,
    });
    if (!sent) return false;

    _awaitingAck.add(clientMsgId);
    _sendTimers[clientMsgId]?.cancel();
    _sendTimers[clientMsgId] = Timer(sendTimeout, () {
      _sendTimers.remove(clientMsgId);
      if (_scopeClosed) return;
      if (_awaitingAck.remove(clientMsgId)) {
        unawaited(_dao.markFailed(clientMsgId));
        unawaited(checkConnection());
      }
    });
    return true;
  }

  Future<void> checkConnection() async {
    if (_scopeClosed) return;
    if (_channel == null) {
      await connect();
      return;
    }
    if (!_write({'type': 'ping'})) _onDisconnected();
  }

  bool _write(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel == null || _scopeClosed) return false;
    try {
      channel.sink.add(jsonEncode(event));
      return true;
    } catch (error) {
      debugPrint('ChatSocket write failed: $error');
      _onDisconnected(error);
      return false;
    }
  }

  void _onData(dynamic raw) {
    if (_scopeClosed || raw is! String) return;
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
      case 'history_cleared':
        unawaited(_handleHistoryCleared(decoded));
      case 'presence':
        _handlePresence(decoded);
      case 'conversation_updated':
        unawaited(_handleConversationUpdated(decoded));
      case 'error':
        unawaited(_handleError(decoded));
      default:
        return;
    }
  }

  Future<void> _handleMessage(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    try {
      final message = Message.fromJson({
        'id': frame['message_id'],
        'conversation_id': frame['conversation_id'],
        'seq': frame['seq'],
        'sender_id': frame['sender_id'],
        'client_msg_id': frame['client_msg_id'],
        'type': frame['msg_type'],
        'content': frame['content'],
        'created_at': frame['created_at'],
      });
      final senderName = frame['sender_name'] as String?;

      final barrier = _syncBarrier;
      if (barrier != null) await barrier.future;
      if (_scopeClosed) return;

      var persisted = false;
      await _serializeMessages(message.conversationId, () async {
        if (_scopeClosed) return;
        final cursor = await _dao.effectiveCursor(message.conversationId);
        if (message.seq > cursor + 1) {
          final synced = await _syncConversation(
            message.conversationId,
            cursor,
          );
          if (_scopeClosed) return;
          if (synced < message.seq - 1) return;
        }
        await _persistServerMessage(message, isHistoricBackfill: false);
        if (_scopeClosed) return;
        acknowledgeDelivered(message.conversationId, message.seq);
        persisted = true;
      });
      if (persisted && !_scopeClosed) unawaited(_emitIncoming(message, senderName));
    } catch (error) {
      debugPrint('ChatSocket failed to persist message: $error');
    }
  }

  Future<void> _emitIncoming(Message message, String? senderName) async {
    if (_scopeClosed) return;
    final listener = onIncomingMessage;
    if (listener == null) return;
    final stored = await _dao.message(message.clientMsgId);
    if (_scopeClosed) return;
    listener(
      Message(
        id: message.id,
        conversationId: message.conversationId,
        seq: message.seq,
        senderId: message.senderId,
        clientMsgId: message.clientMsgId,
        type: message.type,
        content: stored?.content ?? message.content,
        createdAt: message.createdAt,
      ),
      senderName: senderName,
    );
  }

  /// Persists one server message after decrypting an E2EE body.
  ///
  /// Returns `false` when a pre-rotation encrypted body during historic
  /// backfill failed to decrypt and was intentionally dropped instead of
  /// storing a stub row (§2.7).
  Future<bool> _persistServerMessage(
    Message message, {
    bool isHistoricBackfill = false,
  }) async {
    if (_scopeClosed) return false;
    if (await _alreadyReadable(message)) {
      await _dao.upsertServerMessage(message, status: 'sent');
      return true;
    }

    final plaintext = await _decryptForStorage(message);
    if (_scopeClosed) return false;

    final failedDecrypt = isEncryptedContent(message.content) &&
        (plaintext == null ||
            isEncryptedContent(plaintext) ||
            plaintext == undecryptableContent);

    if (failedDecrypt && isHistoricBackfill) {
      final rotatedAt = serverRotatedAt?.call();
      if (rotatedAt != null && message.createdAt.isBefore(rotatedAt)) {
        // Defence in depth (§2.7): pre-rotation ciphertext is cryptographically
        // unreadable; drop it instead of persisting a stub row.
        return false;
      }
    }

    final content = failedDecrypt
        ? undecryptableContent
        : plaintext ?? message.content;
    final stored = content == message.content
        ? message
        : Message(
            id: message.id,
            conversationId: message.conversationId,
            seq: message.seq,
            senderId: message.senderId,
            clientMsgId: message.clientMsgId,
            type: message.type,
            content: content,
            createdAt: message.createdAt,
          );
    await _dao.upsertServerMessage(stored, status: 'sent');
    return true;
  }

  Future<String?> _decryptForStorage(Message message) async {
    if (_scopeClosed) return null;
    final decryptor = decrypt;
    if (decryptor == null || message.type != 'text') return null;
    if (!isEncryptedContent(message.content)) return null;
    try {
      final isGroup =
          await _dao.conversationType(message.conversationId) == 'group';
      if (_scopeClosed) return null;
      return await decryptor(
        message.conversationId,
        message.clientMsgId,
        message.senderId,
        message.content,
        isGroup: isGroup,
      );
    } catch (error, stack) {
      debugPrint('ChatSocket could not decrypt message: $error');
      logger?.error(
        'e2ee',
        'decrypt threw',
        meta: {
          'message_id': message.clientMsgId,
          'conversation_id': message.conversationId,
          'sender_id': message.senderId,
          'exception': error.runtimeType.toString(),
        },
      );
      CrashReporter.record(error, stack, reason: 'e2ee_decrypt_failed');
      return null;
    }
  }

  Future<void> _handleStatus(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final clientMsgId = frame['client_msg_id'];
    final status = frame['status'];
    if (clientMsgId is! String || status is! String) return;

    if (status == 'sent' || status == 'delivered' || status == 'read') {
      _awaitingAck.remove(clientMsgId);
      _sendTimers.remove(clientMsgId)?.cancel();
    }
    final seq = frame['seq'];
    await _dao.applyStatus(
      clientMsgId,
      status,
      seq: seq is num ? seq.toInt() : null,
    );
  }

  Future<void> _handleError(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final code = frame['code'];
    final message = frame['message'];
    debugPrint('ChatSocket server error: $code $message');
    logger?.warn(
      'ws',
      'server error frame',
      meta: {
        if (code is String) 'code': code,
        if (message is String) 'detail': message,
      },
    );

    final clientMsgId = frame['client_msg_id'];
    if (clientMsgId is String && clientMsgId.isNotEmpty) {
      _awaitingAck.remove(clientMsgId);
      _sendTimers.remove(clientMsgId)?.cancel();
      await _dao.markFailed(clientMsgId);
    }
  }

  Future<void> _handleReadReceipt(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final conversationId = frame['conversation_id'];
    final seq = frame['seq'];
    final readCount = frame['read_count'];
    final memberCount = frame['member_count'];
    if (conversationId is! String ||
        seq is! num ||
        readCount is! num ||
        memberCount is! num) {
      return;
    }

    final selfId = await _selfId();
    if (selfId == null || _scopeClosed) return;
    await _dao.applyReadReceipt(
      conversationId: conversationId,
      selfId: selfId,
      upToSeq: seq.toInt(),
      readCount: readCount.toInt(),
      memberCount: memberCount.toInt(),
    );
  }

  Future<void> _handleConversationUpdated(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final conversationId = frame['conversation_id'];
    if (conversationId is! String) return;

    final selfId = await _selfId();
    final tokenBefore = _disconnectToken;
    try {
      final conversation = await _api.conversation(conversationId);
      if (_scopeClosed || tokenBefore != _disconnectToken) return;
      final barrier = _syncBarrier;
      if (barrier != null) await barrier.future;
      if (_scopeClosed || tokenBefore != _disconnectToken) return;
      await _serializeMessages(conversationId, () async {
        if (_scopeClosed) return;
        await _dao.upsertConversation(conversation, selfId: selfId);
        await _syncSummary(conversation, disconnectToken: tokenBefore);
      });
    } on ApiException catch (error) {
      if (_scopeClosed) return;
      if (error.statusCode == 403 || error.statusCode == 404) {
        await _dao.deleteConversation(conversationId);
      }
    } catch (error) {
      debugPrint('ChatSocket refresh conversation failed: $error');
    }
  }

  Future<void> _handleReadState(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final conversationId = frame['conversation_id'];
    final seq = frame['seq'];
    if (conversationId is! String || seq is! num) return;

    await _dao.setReadCursor(conversationId, seq.toInt());
    await _dao.clearUnread(conversationId);
  }

  /// Another device (or key rotation) advanced this member's `cleared_seq`
  /// watermark. Apply it locally so cleared rows disappear immediately (§3.5).
  Future<void> _handleHistoryCleared(Map<String, dynamic> frame) async {
    if (_scopeClosed) return;
    final conversationId = frame['conversation_id'];
    final clearedSeq = frame['cleared_seq'];
    if (conversationId is! String || clearedSeq is! num) return;

    await _serializeMessages(conversationId, () async {
      if (_scopeClosed) return;
      await _dao.applyClearedSeq(conversationId, clearedSeq.toInt());
    });
  }

  /// Exposed for tests simulating an inbound server frame without a live socket.
  @visibleForTesting
  Future<void> handleServerFrameForTesting(Map<String, dynamic> frame) async {
    switch (frame['type']) {
      case 'message':
        await _handleMessage(frame);
      case 'history_cleared':
        await _handleHistoryCleared(frame);
      case 'read_state':
        await _handleReadState(frame);
      case 'status':
        await _handleStatus(frame);
    }
  }

  void _handlePresence(Map<String, dynamic> frame) {
    if (_scopeClosed) return;
    final userId = frame['user_id'];
    final online = frame['online'];
    if (userId is! String || online is! bool) return;

    _presenceController.add(
      Presence.fromJson({
        'user_id': userId,
        'online': online,
        'status': frame['status'],
        'custom_status': frame['custom_status'],
        'last_seen_at': frame['last_seen_at'],
      }),
    );
  }

  void setPresence({required String status, String? customStatus}) {
    _write({
      'type': 'presence',
      'status': status,
      'custom_status': ?customStatus,
    });
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_scopeClosed) return;
      if (!_write({'type': 'ping'})) _onDisconnected();
    });
  }

  void _startOutboxRetry() {
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_scopeClosed && isConnected) unawaited(flushOutbox());
    });
  }

  void _onDisconnected([Object? error]) {
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
    if (_scopeClosed) return;

    connection.value = SocketStatus.disconnected(error?.toString());
    if (error != null) {
      logger?.warn('ws', 'disconnected', meta: {'error': error.toString()});
    }
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
    await disconnect();
    _reconnect?.cancel();
    connection.dispose();
    await _presenceController.close();
  }
}
