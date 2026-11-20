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
