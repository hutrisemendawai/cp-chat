import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/media/media_service.dart';
import '../../core/models/models.dart';
import '../../core/network/api_client.dart';
import '../../core/network/ws_client.dart';
import '../../core/providers.dart';

/// Thrown when a direct chat could not be encrypted for delivery.
///
/// The message is not sent at all: transmitting it as plaintext would silently
/// downgrade the conversation even though the peer has published keys.
class E2eeSendException implements Exception {
  const E2eeSendException();

  @override
  String toString() => 'This chat is end-to-end encrypted and the message '
      'could not be encrypted. Nothing was sent.';
}

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
  ///
  /// Direct chats are end-to-end encrypted: the body is replaced with a
  /// ciphertext envelope before it reaches the socket, so the server only
  /// relays opaque bytes. Groups and media messages keep their current
  /// behaviour.
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    final user = _user;
    if (trimmed.isEmpty || user == null) return;

    final dao = _ref.read(chatDaoProvider);
    final conversation = await dao.conversation(_conversationId);
    final isGroup = conversation?.type == 'group';

    final body = await _ref.read(e2eeManagerProvider).encryptForConversation(
          conversationId: _conversationId,
          plaintext: trimmed,
          isGroup: isGroup,
          peerId: conversation?.peerId,
        );
    // A null body means the direct chat is encrypted but this message could not
    // be: refuse to send rather than leak the plaintext to the server.
    if (body == null) {
      throw const E2eeSendException();
    }

    await _socket.send(
      conversationId: _conversationId,
      senderId: user.id,
      clientMsgId: _uuid.v4(),
      // The bubble shows the text the user typed; the wire carries the
      // ciphertext envelope if the conversation is encrypted.
      content: trimmed,
      wireContent: body,
    );
  }

  /// Sends an image: compress, upload to object storage, then send an
  /// `image` message whose content is the returned object key.
  Future<void> sendImage(
    File file, {
    String? caption,
    void Function(int sent, int total)? onProgress,
  }) async {
    final key = await _ref
        .read(mediaServiceProvider)
        .uploadImage(file: file, onProgress: onProgress);
    await _sendMedia(key, 'image', caption);
  }

  /// Sends an arbitrary file attachment (no re-encoding).
  Future<void> sendFile(
    File file, {
    required String? displayName,
    required String? contentType,
    String? caption,
    void Function(int sent, int total)? onProgress,
  }) async {
    final key = await _ref.read(mediaServiceProvider).uploadFile(
          file: file,
          displayName: displayName,
          contentType: contentType,
          onProgress: onProgress,
        );
    await _sendMedia(key, 'file', caption);
  }

  Future<void> _sendMedia(String objectKey, String type, String? caption) async {
    final user = _user;
    if (user == null) return;
    await _socket.send(
      conversationId: _conversationId,
      senderId: user.id,
      clientMsgId: _uuid.v4(),
      content: joinMediaContent(objectKey, caption),
      type: type,
    );
  }

  Future<void> retry(String clientMsgId) => _socket.retry(_conversationId, clientMsgId);

  Future<void> discard(String clientMsgId) => _socket.discard(clientMsgId);

  /// Marks the conversation read up to the newest message received from someone
  /// else. Acking your own messages would bounce a spurious "read" tick back to
  /// yourself in a direct chat.
  Future<void> markRead() async {
    final dao = _ref.read(chatDaoProvider);
    final user = _user;
    if (user == null) return;

    final latest = await dao.latestSeqFromOthers(_conversationId, user.id);
    if (latest <= 0) return;

    final conversation = await dao.conversation(_conversationId);
    if (conversation != null && conversation.lastReadSeq >= latest) return;
    await _socket.acknowledgeRead(_conversationId, latest);
  }

  /// Loads older history (backwards pagination) into the local mirror.
  Future<bool> loadOlder({int limit = 50}) async {
    final oldestSeq = await _oldestSeq();
    final page = await _api.messages(
      _conversationId,
      beforeSeq: oldestSeq > 1 ? oldestSeq : null,
      limit: limit,
    );
    // History is stored through the socket so encrypted bodies are decrypted
    // before they reach the local mirror.
    await _socket.storeServerMessages(page.messages);
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
  ref.watch(accountScopeProvider);
  return ChatController(ref, conversationId);
});
