import 'dart:convert';

/// Typed models mirroring the frozen REST/WS contracts in `docs/`.

class User {
  const User({
    required this.id,
    required this.name,
    this.nickname,
    this.avatarUrl,
    this.phoneOrEmail,
    this.status,
    this.effectiveStatus,
    this.customStatus,
    this.bio,
    this.lastSeenAt,
    this.isFriend = false,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    final lastSeen = json['last_seen_at'];
    final effective = json['effective_status'] as String?;
    return User(
      id: json['id'] as String,
      name: json['name'] as String,
      nickname: json['nickname'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      phoneOrEmail: json['phone_or_email'] as String?,
      status: json['status'] as String?,
      effectiveStatus: effective ?? (json['status'] as String?),
      customStatus: json['custom_status'] as String?,
      bio: json['bio'] as String?,
      lastSeenAt: lastSeen is String ? DateTime.parse(lastSeen).toUtc() : null,
      isFriend: json['is_friend'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String? nickname;
  final String? avatarUrl;
  final String? phoneOrEmail;

  /// The presence preference (`online`/`idle`/`dnd`/`invisible`).
  final String? status;

  /// What peers actually see (`online`/`idle`/`dnd`/`offline`).
  final String? effectiveStatus;

  final String? customStatus;
  final String? bio;
  final DateTime? lastSeenAt;

  /// Whether the current caller has this user in their friends list.
  final bool isFriend;

  /// "Name (nickname)" when a nickname is set, otherwise the plain name.
  String get displayName {
    final nick = nickname?.trim();
    return nick != null && nick.isNotEmpty ? '$name ($nick)' : name;
  }

  /// Copy with a replacement presence preference, used after a profile edit.
  User copyWith({
    String? name,
    String? nickname,
    String? avatarUrl,
    String? status,
    String? effectiveStatus,
    String? customStatus,
    String? bio,
    DateTime? lastSeenAt,
    bool clearNickname = false,
    bool clearCustomStatus = false,
    bool clearBio = false,
    bool clearAvatar = false,
  }) {
    return User(
      id: id,
      name: name ?? this.name,
      nickname: clearNickname ? null : (nickname ?? this.nickname),
      avatarUrl: clearAvatar ? null : (avatarUrl ?? this.avatarUrl),
      phoneOrEmail: phoneOrEmail,
      status: status ?? this.status,
      effectiveStatus: effectiveStatus ?? this.effectiveStatus,
      customStatus: clearCustomStatus ? null : (customStatus ?? this.customStatus),
      bio: clearBio ? null : (bio ?? this.bio),
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isFriend: isFriend,
    );
  }
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
    this.avatarUrl,
    this.lastMessage,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        type: json['type'] as String,
        name: json['name'] as String?,
        avatarUrl: json['avatar_url'] as String?,
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
  final String? avatarUrl;
  final List<ConversationMember> members;
  final int lastSeq;
  final int lastReadSeq;
  final int unreadCount;
  final DateTime createdAt;
  final Message? lastMessage;

  bool get isGroup => type == 'group';

  /// The other participant of a direct conversation, `null` for groups.
  ConversationMember? otherMember(String selfId) {
    for (final member in members) {
      if (member.user.id != selfId) return member;
    }
    return null;
  }

  ConversationMember? memberOf(String userId) {
    for (final member in members) {
      if (member.user.id == userId) return member;
    }
    return null;
  }

  bool isAdmin(String userId) => memberOf(userId)?.role == 'admin';

  String displayName(String selfId) {
    if (type == 'group') return name ?? 'Group';
    return otherMember(selfId)?.user.displayName ?? 'Chat';
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

/// Result of `POST /api/v1/media/presign`: upload the bytes to [uploadUrl],
/// then send a message whose `content` is [objectKey].
class MediaUpload {
  const MediaUpload({
    required this.mediaId,
    required this.objectKey,
    required this.uploadUrl,
    required this.contentType,
    required this.sizeBytes,
    required this.expiresAt,
  });

  factory MediaUpload.fromJson(Map<String, dynamic> json) => MediaUpload(
        mediaId: json['media_id'] as String,
        objectKey: json['object_key'] as String,
        uploadUrl: json['upload_url'] as String,
        contentType: json['content_type'] as String? ?? 'application/octet-stream',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      );

  final String mediaId;
  final String objectKey;
  final String uploadUrl;
  final String contentType;
  final int sizeBytes;
  final DateTime expiresAt;
}

/// Aggregated group read state for a message the current user sent.
class ReadReceipt {
  const ReadReceipt({
    required this.conversationId,
    required this.seq,
    required this.readCount,
    required this.memberCount,
  });

  factory ReadReceipt.fromJson(Map<String, dynamic> json) => ReadReceipt(
        conversationId: json['conversation_id'] as String,
        seq: (json['seq'] as num).toInt(),
        readCount: (json['read_count'] as num?)?.toInt() ?? 0,
        memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      );

  final String conversationId;
  final int seq;
  final int readCount;
  final int memberCount;
}

/// Online state for a user, from `GET /api/v1/presence/{id}` or a live
/// `presence` WebSocket frame.
class Presence {
  const Presence({
    required this.userId,
    required this.online,
    this.status = '',
    this.customStatus,
    this.lastSeenAt,
  });

  factory Presence.fromJson(Map<String, dynamic> json) {
    final lastSeen = json['last_seen_at'];
    final status = json['status'] as String?;
    final online = json['online'] as bool? ?? false;
    return Presence(
      userId: json['user_id'] as String,
      online: online,
      // Fall back to online/offline for a server that predates Discord statuses.
      status: status ?? (online ? 'online' : 'offline'),
      customStatus: json['custom_status'] as String?,
      lastSeenAt: lastSeen is String ? DateTime.parse(lastSeen).toUtc() : null,
    );
  }

  final String userId;
  final bool online;

  /// `online` | `idle` | `dnd` | `offline`, or empty when only [online] is known.
  final String status;
  final String? customStatus;
  final DateTime? lastSeenAt;

  /// The Discord-style status, deriving it from [online] when absent.
  String get resolvedStatus => status.isEmpty ? (online ? 'online' : 'offline') : status;

  /// True for the three visible connected states.
  bool get isActive =>
      resolvedStatus == 'online' || resolvedStatus == 'idle' || resolvedStatus == 'dnd';
}

/// A message search hit. Carries the conversation it belongs to so global
/// results can be grouped and opened.
class SearchHit {
  const SearchHit({required this.message, required this.rank});

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        message: Message.fromJson(json),
        rank: (json['rank'] as num?)?.toDouble() ?? 0,
      );

  final Message message;
  final double rank;
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
