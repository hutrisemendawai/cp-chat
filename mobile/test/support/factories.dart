import 'package:cp_chat/core/models/models.dart';

/// Builders for contract-shaped models in tests.
Message message(
  String clientMsgId, {
  String conversationId = 'conv-1',
  int seq = 1,
  String senderId = 'them',
  String type = 'text',
  String content = 'hello',
  DateTime? createdAt,
}) {
  return Message(
    id: 'server-$clientMsgId',
    conversationId: conversationId,
    seq: seq,
    senderId: senderId,
    clientMsgId: clientMsgId,
    type: type,
    content: content,
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
  );
}

User user(
  String id, {
  String? name,
  String? username,
  String? nickname,
  String? avatarKey,
  String? phoneOrEmail,
  String? status,
  String? effectiveStatus,
  String? customStatus,
}) =>
    User(
      id: id,
      name: name ?? id,
      username: username,
      nickname: nickname,
      avatarUrl: avatarKey,
      phoneOrEmail: phoneOrEmail,
      status: status,
      effectiveStatus: effectiveStatus,
      customStatus: customStatus,
    );

Conversation conversation(
  String id, {
  required String selfId,
  String peerId = 'them',
  String peerName = 'Them',
  String? peerNickname,
  String? peerAvatarKey,
  int lastSeq = 0,
  int lastReadSeq = 0,
  int unreadCount = 0,
  Message? lastMessage,
  String type = 'direct',
  String? name,
  String? avatarKey,
}) {
  return Conversation(
    id: id,
    type: type,
    name: name,
    avatarUrl: avatarKey,
    members: [
      ConversationMember(user: user(selfId), role: 'member', lastReadSeq: lastReadSeq),
      ConversationMember(
        user: user(
          peerId,
          name: peerName,
          nickname: peerNickname,
          avatarKey: peerAvatarKey,
        ),
        role: 'member',
        lastReadSeq: 0,
      ),
    ],
    lastSeq: lastSeq,
    lastReadSeq: lastReadSeq,
    unreadCount: unreadCount,
    createdAt: DateTime.utc(2026, 1, 1),
    lastMessage: lastMessage,
  );
}
