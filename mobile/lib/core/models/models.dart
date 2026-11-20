import 'dart:convert';

/// Typed models mirroring the frozen REST/WS contracts in `docs/`.

class User {
  const User({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.phoneOrEmail,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        phoneOrEmail: json['phone_or_email'] as String?,
      );

  final String id;
  final String name;
  final String? avatarUrl;
  final String? phoneOrEmail;
}

class AuthSession {
  const AuthSession({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        user: User.fromJson(json['user'] as Map<String, dynamic>),
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresIn: (json['expires_in'] as num).toInt(),
      );

  final User user;
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  factory TokenPair.fromJson(Map<String, dynamic> json) => TokenPair(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresIn: (json['expires_in'] as num).toInt(),
      );

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.seq,
    required this.senderId,
    required this.clientMsgId,
    required this.type,
    required this.content,
    required this.createdAt,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        seq: (json['seq'] as num).toInt(),
        senderId: json['sender_id'] as String,
        clientMsgId: json['client_msg_id'] as String,
        type: json['type'] as String,
        content: json['content'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      );

  final String id;
  final String conversationId;
  final int seq;
  final String senderId;
  final String clientMsgId;
  final String type;
  final String content;
  final DateTime createdAt;
}

class ConversationMember {
  const ConversationMember({
    required this.user,
    required this.role,
    required this.lastReadSeq,
  });

  factory ConversationMember.fromJson(Map<String, dynamic> json) =>
      ConversationMember(
        user: User.fromJson(json['user'] as Map<String, dynamic>),
        role: json['role'] as String,
        lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
      );

  final User user;
  final String role;
  final int lastReadSeq;
}

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    required this.members,
    required this.lastSeq,
    required this.lastReadSeq,
    required this.unreadCount,
    required this.createdAt,
    this.name,
    this.lastMessage,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        type: json['type'] as String,
        name: json['name'] as String?,
        members: (json['members'] as List<dynamic>)
            .map((member) => ConversationMember.fromJson(member as Map<String, dynamic>))
            .toList(),
        lastSeq: (json['last_seq'] as num?)?.toInt() ?? 0,
        lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
        unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
        lastMessage: json['last_message'] == null
            ? null
            : Message.fromJson(json['last_message'] as Map<String, dynamic>),
      );

  final String id;
  final String type;
  final String? name;
  final List<ConversationMember> members;
  final int lastSeq;
  final int lastReadSeq;
  final int unreadCount;
  final DateTime createdAt;
  final Message? lastMessage;

  /// The other participant of a direct conversation, `null` for groups.
  ConversationMember? otherMember(String selfId) {
    for (final member in members) {
      if (member.user.id != selfId) return member;
    }
    return null;
  }

  String displayName(String selfId) {
    if (type == 'group') return name ?? 'Group';
    return otherMember(selfId)?.user.name ?? 'Chat';
  }
}

class MessagePage {
  const MessagePage({required this.messages, required this.hasMore});

  factory MessagePage.fromJson(Map<String, dynamic> json) => MessagePage(
        messages: (json['messages'] as List<dynamic>)
            .map((message) => Message.fromJson(message as Map<String, dynamic>))
            .toList(),
        hasMore: json['has_more'] as bool,
      );

  final List<Message> messages;
  final bool hasMore;
}

class SyncResult {
  const SyncResult({required this.messages, required this.latestSeq});

  factory SyncResult.fromJson(Map<String, dynamic> json) => SyncResult(
        messages: (json['messages'] as List<dynamic>)
            .map((message) => Message.fromJson(message as Map<String, dynamic>))
            .toList(),
        latestSeq: (json['latest_seq'] as num).toInt(),
      );

  final List<Message> messages;
  final int latestSeq;
}

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.statusCode});

  factory ApiException.fromResponse(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error'] as Map<String, dynamic>?;
      if (error != null) {
        return ApiException(
          error['code'] as String? ?? 'unknown',
          error['message'] as String? ?? 'Request failed',
          statusCode: statusCode,
        );
      }
    } catch (_) {
      // Fall through to a generic message.
    }
    return ApiException('unknown', 'Request failed ($statusCode)', statusCode: statusCode);
  }

  final String code;
  final String message;
  final int? statusCode;

  bool get isAuthFailure => statusCode == 401;

  @override
  String toString() => message;
}
