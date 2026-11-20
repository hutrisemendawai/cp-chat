import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/models.dart';
import '../../core/network/api_client.dart';
import '../../core/network/ws_client.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/providers.dart';

/// Sending, retrying and read-acknowledging for a single conversation.
class ChatController {
  ChatController(this._ref, this._conversationId);

  final Ref _ref;
  final String _conversationId;
  final Uuid _uuid = const Uuid();

  ChatSocket get _socket => _ref.read(chatSocketProvider);
  ApiClient get _api => _ref.read(apiClientProvider);
  User? get _user => _ref.read(currentUserProvider);

  /// Persists an optimistic row first, then sends. The UI renders from the local
  /// mirror, so the bubble appears immediately with a clock icon.
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    final user = _user;
    if (trimmed.isEmpty || user == null) return;

    await _socket.send(
      conversationId: _conversationId,
      senderId: user.id,
      clientMsgId: _uuid.v4(),
      content: trimmed,
    );
  }

  Future<void> retry(String clientMsgId) => _socket.retry(_conversationId, clientMsgId);

  Future<void> discard(String clientMsgId) => _socket.discard(clientMsgId);

  /// Marks the conversation read up to the newest persisted `seq`.
  Future<void> markRead() async {
    final dao = _ref.read(chatDaoProvider);
    final maxSeq = await dao.localMaxSeq(_conversationId);
    if (maxSeq <= 0) return;

    final conversation = await dao.conversation(_conversationId);
    if (conversation != null && conversation.lastReadSeq >= maxSeq) return;
    await _socket.acknowledgeRead(_conversationId, maxSeq);
  }

  /// Loads older history (backwards pagination) into the local mirror.
  Future<bool> loadOlder({int limit = 50}) async {
    final dao = _ref.read(chatDaoProvider);
    final oldestSeq = await _oldestSeq();
    final page = await _api.messages(
      _conversationId,
      beforeSeq: oldestSeq > 1 ? oldestSeq : null,
      limit: limit,
    );
    await dao.upsertServerMessages(page.messages);
    return page.hasMore;
  }

  Future<int> _oldestSeq() async {
    final messages = await _ref.read(chatDaoProvider).watchMessages(_conversationId).first;
    for (final message in messages) {
      if (message.seq != null) return message.seq!;
    }
    return 0;
  }
}

final chatControllerProvider =
    Provider.family<ChatController, String>((ref, conversationId) {
  return ChatController(ref, conversationId);
});

/// Registers this install for push delivery once a session exists and keeps the
/// registration current when Firebase rotates the installation id.
class PushRegistration {
  PushRegistration(this._api);

  final ApiClient _api;
  StreamSubscription<String>? _refresh;

  Future<void> start() async {
    final fid = await FcmService.currentToken();
    if (fid != null) {
      try {
        await _api.registerFcmToken(fid);
      } catch (error) {
        debugPrint('FCM registration failed: $error');
      }
    }

    _refresh ??= FcmService.onTokenRefresh.listen((next) async {
      try {
        await _api.registerFcmToken(next);
      } catch (error) {
        debugPrint('FCM refresh registration failed: $error');
      }
    });
  }

  Future<void> stop() async {
    await _refresh?.cancel();
    _refresh = null;
  }
}
