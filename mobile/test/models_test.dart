import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/models/models.dart';

void main() {
  group('model parsing', () {
    test('parses an auth session with the user contact', () {
      final session = AuthSession.fromJson(
        jsonDecode('''
        {
          "user": {"id": "u1", "name": "Alice", "avatar_url": null,
                   "phone_or_email": "alice@example.com", "created_at": "2026-01-01T00:00:00Z"},
          "access_token": "access",
          "refresh_token": "refresh",
          "expires_in": 900
        }
        ''') as Map<String, dynamic>,
      );

      expect(session.user.id, 'u1');
      expect(session.user.phoneOrEmail, 'alice@example.com');
      expect(session.accessToken, 'access');
      expect(session.expiresIn, 900);
    });

    test('parses a message with a UTC timestamp', () {
      final message = Message.fromJson(
        jsonDecode('''
        {
          "id": "m1", "conversation_id": "c1", "seq": 42, "sender_id": "u1",
          "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
          "type": "text", "content": "Hello!",
          "created_at": "2026-11-20T08:00:00Z"
        }
        ''') as Map<String, dynamic>,
      );

      expect(message.seq, 42);
      expect(message.createdAt.isUtc, isTrue);
      expect(message.content, 'Hello!');
    });

    test('parses a direct conversation and resolves the other member', () {
      final conversation = Conversation.fromJson(
        jsonDecode('''
        {
          "id": "c1", "type": "direct", "name": null, "created_by": "u1",
          "last_seq": 7, "last_read_seq": 3, "unread_count": 4,
          "created_at": "2026-01-01T00:00:00Z",
          "members": [
            {"user": {"id": "u1", "name": "Alice", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 3},
            {"user": {"id": "u2", "name": "Bob", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0}
          ],
          "last_message": null
        }
        ''') as Map<String, dynamic>,
      );

      expect(conversation.lastSeq, 7);
      expect(conversation.unreadCount, 4);
      expect(conversation.otherMember('u1')!.user.name, 'Bob');
      expect(conversation.displayName('u1'), 'Bob');
      expect(conversation.lastMessage, isNull);
    });

    test('a group suggests its name instead of a peer', () {
      final conversation = Conversation.fromJson(
        jsonDecode('''
        {
          "id": "c1", "type": "group", "name": "Team", "created_by": "u1",
          "last_seq": 0, "last_read_seq": 0, "unread_count": 0,
          "created_at": "2026-01-01T00:00:00Z",
          "members": [], "last_message": null
        }
        ''') as Map<String, dynamic>,
      );

      expect(conversation.displayName('u1'), 'Team');
      expect(conversation.otherMember('u1'), isNull);
    });

    test('a group never resolves an other member even with members present', () {
      final conversation = Conversation.fromJson(
        jsonDecode('''
        {
          "id": "g1", "type": "group", "name": "Team", "created_by": "u1",
          "last_seq": 0, "last_read_seq": 0, "unread_count": 0,
          "created_at": "2026-01-01T00:00:00Z",
          "members": [
            {"user": {"id": "u1", "name": "Alice", "created_at": "2026-01-01T00:00:00Z"},
             "role": "admin", "last_read_seq": 0},
            {"user": {"id": "u2", "name": "Bob", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0},
            {"user": {"id": "u3", "name": "Carol", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0}
          ],
          "last_message": null
        }
        ''') as Map<String, dynamic>,
      );

      expect(conversation.isGroup, isTrue);
      expect(conversation.otherMember('u1'), isNull);
      expect(conversation.displayName('u1'), 'Team');
    });

    test('parses a message page and sync result', () {
      final page = MessagePage.fromJson(
        jsonDecode('{"messages": [], "has_more": true}') as Map<String, dynamic>,
      );
      final sync = SyncResult.fromJson(
        jsonDecode('{"messages": [], "latest_seq": 12}') as Map<String, dynamic>,
      );

      expect(page.hasMore, isTrue);
      expect(page.messages, isEmpty);
      expect(sync.latestSeq, 12);
    });

    test('parses a group avatar and admin role', () {
      final conversation = Conversation.fromJson(
        jsonDecode('''
        {
          "id": "g1", "type": "group", "name": "Team",
          "avatar_url": "owner/2026/11/avatar.jpg", "created_by": "u1",
          "last_seq": 0, "last_read_seq": 0, "unread_count": 0,
          "created_at": "2026-01-01T00:00:00Z",
          "members": [
            {"user": {"id": "u1", "name": "Alice", "created_at": "2026-01-01T00:00:00Z"},
             "role": "admin", "last_read_seq": 0},
            {"user": {"id": "u2", "name": "Bob", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0}
          ],
          "last_message": null
        }
        ''') as Map<String, dynamic>,
      );

      expect(conversation.isGroup, isTrue);
      expect(conversation.avatarUrl, 'owner/2026/11/avatar.jpg');
      expect(conversation.isAdmin('u1'), isTrue);
      expect(conversation.isAdmin('u2'), isFalse);
      expect(conversation.memberOf('u2')!.user.name, 'Bob');
    });

    test('parses a media presign response', () {
      final upload = MediaUpload.fromJson(
        jsonDecode('''
        {
          "media_id": "m1", "object_key": "u1/2026/11/a.jpg",
          "upload_url": "http://localhost:9000/bucket/u1/2026/11/a.jpg?sig=x",
          "file_url": "http://localhost:9000/bucket/u1/2026/11/a.jpg",
          "content_type": "image/jpeg", "size_bytes": 2048,
          "expires_at": "2026-11-20T09:00:00Z"
        }
        ''') as Map<String, dynamic>,
      );

      expect(upload.objectKey, 'u1/2026/11/a.jpg');
      expect(upload.uploadUrl, contains('sig=x'));
      expect(upload.contentType, 'image/jpeg');
      expect(upload.sizeBytes, 2048);
      expect(upload.expiresAt.isUtc, isTrue);
    });

    test('parses an aggregated read receipt', () {
      final receipt = ReadReceipt.fromJson(
        jsonDecode('''
        {"conversation_id": "g1", "seq": 42, "read_count": 3, "member_count": 8}
        ''') as Map<String, dynamic>,
      );

      expect(receipt.seq, 42);
      expect(receipt.readCount, 3);
      expect(receipt.memberCount, 8);
    });

    test('parses a profile with nickname, status, custom status and bio', () {
      final user = User.fromJson(
        jsonDecode('''
        {
          "id": "u1", "name": "Alice", "nickname": "ally",
          "avatar_url": "u1/a.jpg", "status": "dnd",
          "effective_status": "dnd", "custom_status": "heads down",
          "bio": "Hello there", "phone_or_email": "alice@example.com",
          "last_seen_at": "2026-01-01T00:00:00Z"
        }
        ''') as Map<String, dynamic>,
      );

      expect(user.nickname, 'ally');
      expect(user.status, 'dnd');
      expect(user.effectiveStatus, 'dnd');
      expect(user.customStatus, 'heads down');
      expect(user.bio, 'Hello there');
      expect(user.lastSeenAt, DateTime.utc(2026, 1, 1));
    });

    test('displayName renders "Name (nickname)" only when a nickname is set', () {
      const withNickname = User(id: 'u1', name: 'Alice', nickname: 'ally');
      const blankNickname = User(id: 'u1', name: 'Alice', nickname: '   ');
      const noNickname = User(id: 'u1', name: 'Alice');

      expect(withNickname.displayName, 'Alice (ally)');
      expect(blankNickname.displayName, 'Alice');
      expect(noNickname.displayName, 'Alice');
    });

    test('a direct conversation display name uses the peer nickname', () {
      final conversation = Conversation.fromJson(
        jsonDecode('''
        {
          "id": "c1", "type": "direct", "name": null, "created_by": "u1",
          "last_seq": 0, "last_read_seq": 0, "unread_count": 0,
          "created_at": "2026-01-01T00:00:00Z",
          "members": [
            {"user": {"id": "u1", "name": "Alice", "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0},
            {"user": {"id": "u2", "name": "Bob", "nickname": "bo",
                      "created_at": "2026-01-01T00:00:00Z"},
             "role": "member", "last_read_seq": 0}
          ],
          "last_message": null
        }
        ''') as Map<String, dynamic>,
      );

      expect(conversation.displayName('u1'), 'Bob (bo)');
    });

    test('parses a Discord presence snapshot with status and custom status', () {
      final presence = Presence.fromJson({
        'user_id': 'u1',
        'online': true,
        'status': 'idle',
        'custom_status': 'brb',
        'last_seen_at': null,
      });

      expect(presence.resolvedStatus, 'idle');
      expect(presence.customStatus, 'brb');
      expect(presence.isActive, isTrue);
    });

    test('an invisible presence is not active', () {
      final presence = Presence.fromJson({
        'user_id': 'u1',
        'online': false,
        'status': 'offline',
      });

      expect(presence.resolvedStatus, 'offline');
      expect(presence.isActive, isFalse);
    });
    test('parses a user with a username', () {
      final user = User.fromJson({
        'id': 'u1',
        'name': 'Alice',
        'username': 'alice',
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(user.username, 'alice');
      expect(user.displayName, 'Alice');
    });

    test('a search result without an email parses cleanly', () {
      final user = User.fromJson({
        'id': 'u1',
        'name': 'Alice',
        'username': 'alice',
        'nickname': null,
        'avatar_url': null,
      });

      expect(user.username, 'alice');
      expect(user.phoneOrEmail, isNull);
    });

    test('parses a paginated user search page', () {
      final page = UserSearchPage.fromJson({
        'users': [
          {'id': 'u1', 'name': 'Alice', 'username': 'alice'},
        ],
        'limit': 10,
        'offset': 0,
        'has_more': true,
        'next_offset': 10,
      });

      expect(page.items.single.username, 'alice');
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 10);
    });

    test('a final search page reports no further offset', () {
      final page = UserSearchPage.fromJson({
        'users': [],
        'limit': 10,
        'offset': 20,
        'has_more': false,
        'next_offset': null,
      });

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.nextOffset, isNull);
    });
  });

  group('ApiException', () {
    test('extracts the contract error envelope', () {
      final error = ApiException.fromResponse(
        409,
        '{"error":{"code":"conflict","message":"Already registered"}}',
      );

      expect(error.code, 'conflict');
      expect(error.message, 'Already registered');
      expect(error.statusCode, 409);
      expect(error.isAuthFailure, isFalse);
    });

    test('flags 401 as an auth failure', () {
      final error = ApiException.fromResponse(
        401,
        '{"error":{"code":"invalid_token","message":"Expired"}}',
      );

      expect(error.isAuthFailure, isTrue);
    });

    test('falls back when the body is not JSON', () {
      final error = ApiException.fromResponse(500, '<html>oops</html>');

      expect(error.code, 'unknown');
      expect(error.message, contains('500'));
    });
  });
}
