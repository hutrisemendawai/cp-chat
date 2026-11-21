import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/features/presence/presence_controller.dart';

void main() {
  group('presence formatting', () {
    final reference = DateTime.utc(2026, 1, 1, 12, 0);

    test('unknown presence renders nothing', () {
      expect(formatPresence(null), isNull);
    });

    test('online takes precedence over last seen', () {
      final presence = Presence(
        userId: 'u1',
        online: true,
        lastSeenAt: reference.subtract(const Duration(hours: 3)),
      );
      expect(formatPresence(presence, now: reference), 'Online');
    });

    test('offline with no timestamp is plain offline', () {
      expect(
        formatPresence(const Presence(userId: 'u1', online: false), now: reference),
        'Offline',
      );
    });

    test('formats relative last seen', () {
      String label(Duration ago) => formatPresence(
            Presence(userId: 'u1', online: false, lastSeenAt: reference.subtract(ago)),
            now: reference,
          )!;

      expect(label(const Duration(seconds: 20)), 'Last seen just now');
      expect(label(const Duration(minutes: 5)), 'Last seen 5m ago');
      expect(label(const Duration(hours: 2)), 'Last seen 2h ago');
      expect(label(const Duration(days: 3)), 'Last seen 3d ago');
      expect(label(const Duration(days: 30)), 'Last seen 2/12');
    });
  });

  group('presence model', () {
    test('parses an online snapshot', () {
      final presence = Presence.fromJson({
        'user_id': 'u1',
        'online': true,
        'last_seen_at': null,
      });
      expect(presence.userId, 'u1');
      expect(presence.online, isTrue);
      expect(presence.lastSeenAt, isNull);
    });

    test('parses an offline snapshot with a timestamp', () {
      final presence = Presence.fromJson({
        'user_id': 'u1',
        'online': false,
        'last_seen_at': '2026-01-01T12:00:00Z',
      });
      expect(presence.online, isFalse);
      expect(presence.lastSeenAt, DateTime.utc(2026, 1, 1, 12));
    });
  });

  group('search hit', () {
    test('decodes the message and rank', () {
      final hit = SearchHit.fromJson({
        'id': 'server-1',
        'conversation_id': 'conv-1',
        'seq': 4,
        'sender_id': 'u2',
        'client_msg_id': 'c1',
        'type': 'text',
        'content': 'project kickoff',
        'created_at': '2026-01-01T12:00:00Z',
        'rank': 0.42,
      });

      expect(hit.message.content, 'project kickoff');
      expect(hit.message.conversationId, 'conv-1');
      expect(hit.rank, closeTo(0.42, 0.0001));
    });
  });
}
