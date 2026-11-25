import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/notifications/fcm_service.dart';
import 'package:cp_chat/core/notifications/local_notification_service.dart';
import 'package:cp_chat/core/notifications/message_notifier.dart';
import 'package:cp_chat/core/notifications/notification_policy.dart';
import 'package:cp_chat/core/notifications/push_registration.dart';
import 'package:cp_chat/core/storage/token_store.dart';

import 'support/factories.dart';

/// Captures what would have been raised in the notification tray.
class _RecordingSink implements MessageNotificationSink {
  final List<({String conversationId, String title, String body, String? messageId})> shown = [];

  @override
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
  }) async {
    shown.add((
      conversationId: conversationId,
      title: title,
      body: body,
      messageId: messageId,
    ));
  }
}

/// Records push-token registrations and can be told to fail a fixed number of
/// times so the retry path is exercised.
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(TokenStore());

  final List<String> tokens = [];
  int attempts = 0;
  int failuresRemaining = 0;

  @override
  Future<void> registerFcmToken(String fid) async {
    attempts += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('offline');
    }
    tokens.add(fid);
  }
}

MessageNotifier _notifier({
  required _RecordingSink sink,
  String? selfId = 'me',
  String? selfStatus = 'online',
  bool appResumed = true,
  String? activeConversationId,
  ConversationNames? names,
}) {
  return MessageNotifier(
    notifications: sink,
    selfId: () => selfId,
    selfStatus: () => selfStatus,
    appResumed: () => appResumed,
    activeConversationId: () => activeConversationId,
    resolveNames: (_) async => names,
  );
}

void main() {
  group('NotificationPolicy.shouldNotify', () {
    bool notify({
      String? senderId,
      String? selfId = 'me',
      String? selfStatus = 'online',
      bool appResumed = true,
      String? activeConversationId,
      String conversationId = 'c1',
    }) =>
        NotificationPolicy.shouldNotify(
          senderId: senderId,
          selfId: selfId,
          selfStatus: selfStatus,
          appResumed: appResumed,
          activeConversationId: activeConversationId,
          conversationId: conversationId,
        );

    test('allows a message from someone else', () {
      expect(notify(senderId: 'you'), isTrue);
    });

    test("skips the caller's own message", () {
      expect(notify(senderId: 'me'), isFalse);
    });

    test('skips a message while on Do Not Disturb', () {
      expect(notify(senderId: 'you', selfStatus: 'dnd'), isFalse);
    });

    test('skips the chat that is open in the foreground', () {
      expect(notify(senderId: 'you', activeConversationId: 'c1'), isFalse);
    });

    test('still notifies the open chat when the app is backgrounded', () {
      expect(
        notify(senderId: 'you', activeConversationId: 'c1', appResumed: false),
        isTrue,
      );
    });

    test('notifies a different chat while another is open', () {
      expect(
        notify(senderId: 'you', activeConversationId: 'c2', conversationId: 'c1'),
        isTrue,
      );
    });
  });

  group('NotificationPolicy.preview', () {
    test('reports an undecryptable body without leaking its ciphertext', () {
      final preview = NotificationPolicy.preview(
        type: 'text',
        content: 'e2ee:v1:{"v":1,"ct":"c2VjcmV0","n":"n","m":"m"}',
      );
      expect(preview, 'Encrypted message');
      expect(preview.contains('e2ee:v1:'), isFalse);
    });

    test('keeps plaintext text', () {
      expect(
        NotificationPolicy.preview(type: 'text', content: '  hello there '),
        'hello there',
      );
    });

    test('describes media attachments', () {
      expect(NotificationPolicy.preview(type: 'image', content: 'key'), 'Sent an image');
      expect(NotificationPolicy.preview(type: 'file', content: 'key'), 'Sent a file');
    });
  });

  group('NotificationPolicy.format', () {
    test('a group body is prefixed with the sender, the title is the group', () {
      final rendered = NotificationPolicy.format(
        isGroup: true,
        conversationName: 'Weekend Squad',
        senderName: 'Bob',
        type: 'text',
        content: 'hi all',
      );
      expect(rendered.title, 'Weekend Squad');
      expect(rendered.body, 'Bob: hi all');
    });

    test('a direct chat uses the peer name as the title', () {
      final rendered = NotificationPolicy.format(
        isGroup: false,
        conversationName: 'Alice',
        type: 'text',
        content: 'hi',
      );
      expect(rendered.title, 'Alice');
      expect(rendered.body, 'hi');
    });
  });

  group('RecentIdSet', () {
    test('drops a repeated id inside the window', () {
      final seen = RecentIdSet(window: const Duration(seconds: 60));
      expect(seen.add('m1'), isTrue);
      expect(seen.add('m1'), isFalse);
      expect(seen.add('m2'), isTrue);
    });

    test('accepts the same id again after the window lapses', () {
      var now = DateTime.utc(2026, 1, 1);
      final seen = RecentIdSet(window: const Duration(seconds: 60), now: () => now);
      expect(seen.add('m1'), isTrue);
      now = now.add(const Duration(seconds: 61));
      expect(seen.add('m1'), isTrue);
    });
  });

  group('MessageNotifier.onLiveMessage', () {
    test('shows a direct-chat notification with the peer name and preview', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        names: (isGroup: false, displayName: 'Alice'),
      );

      await notifier.onLiveMessage(
        message('m1', conversationId: 'c1', senderId: 'you', content: 'hey there'),
      );

      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.conversationId, 'c1');
      expect(sink.shown.single.title, 'Alice');
      expect(sink.shown.single.body, 'hey there');
    });

    test('titles a group with the group name and prefixes the sender', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        names: (isGroup: true, displayName: 'Weekend Squad'),
      );

      await notifier.onLiveMessage(
        message('m1', conversationId: 'g1', senderId: 'bob', content: 'ping'),
        senderName: 'Bob',
      );

      expect(sink.shown.single.title, 'Weekend Squad');
      expect(sink.shown.single.body, 'Bob: ping');
    });

    test('never leaks the raw ciphertext of an undecryptable message', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        names: (isGroup: false, displayName: 'Alice'),
      );

      await notifier.onLiveMessage(
        message(
          'm1',
          conversationId: 'c1',
          senderId: 'you',
          content: 'e2ee:v1:{"v":1,"ct":"c2VjcmV0"}',
        ),
      );

      expect(sink.shown.single.body, 'Encrypted message');
      expect(sink.shown.single.body, isNot(contains('e2ee:v1:')));
    });

    test("skip the caller's own message", () async {
      final sink = _RecordingSink();
      final notifier = _notifier(sink: sink, names: (isGroup: false, displayName: 'Me'));

      await notifier.onLiveMessage(
        message('m1', conversationId: 'c1', senderId: 'me', content: 'from my other device'),
      );

      expect(sink.shown, isEmpty);
    });

    test('skips a message on Do Not Disturb', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        selfStatus: 'dnd',
        names: (isGroup: false, displayName: 'Alice'),
      );

      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));
      expect(sink.shown, isEmpty);
    });

    test('skips the open foreground chat', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        activeConversationId: 'c1',
        names: (isGroup: false, displayName: 'Alice'),
      );

      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));
      expect(sink.shown, isEmpty);
    });

    test('notifies the open chat once the app is backgrounded', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(
        sink: sink,
        appResumed: false,
        activeConversationId: 'c1',
        names: (isGroup: false, displayName: 'Alice'),
      );

      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));
      expect(sink.shown, hasLength(1));
    });

    test('shows a repeated message id only once', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(sink: sink, names: (isGroup: false, displayName: 'Alice'));

      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));
      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));

      expect(sink.shown, hasLength(1));
    });
  });

  group('MessageNotifier.onForegroundFcm', () {
    test('forwards the backend payload', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(sink: sink, names: (isGroup: false, displayName: 'Alice'));

      await notifier.onForegroundFcm(
        conversationId: 'c1',
        messageId: 'm1',
        title: 'Alice',
        body: 'hello',
      );

      expect(sink.shown.single.title, 'Alice');
      expect(sink.shown.single.body, 'hello');
    });

    test('deduplicates a push that repeats a live message', () async {
      final sink = _RecordingSink();
      final notifier = _notifier(sink: sink, names: (isGroup: false, displayName: 'Alice'));

      // The live message id and the FCM `message_id` are the same server id, so
      // the push must not raise a second banner.
      await notifier.onLiveMessage(message('m1', conversationId: 'c1', senderId: 'you'));
      await notifier.onForegroundFcm(
        conversationId: 'c1',
        messageId: 'server-m1',
        title: 'Alice',
        body: 'hello',
      );

      expect(sink.shown, hasLength(1));
    });

    test('respects Do Not Disturb and the open foreground chat', () async {
      final sink = _RecordingSink();
      final dnd = _notifier(sink: sink, selfStatus: 'dnd');
      await dnd.onForegroundFcm(
        conversationId: 'c1',
        messageId: 'm1',
        title: 'Alice',
        body: 'hello',
      );
      expect(sink.shown, isEmpty);

      final active = _notifier(sink: sink, activeConversationId: 'c1');
      await active.onForegroundFcm(
        conversationId: 'c1',
        messageId: 'm2',
        title: 'Alice',
        body: 'hello',
      );
      expect(sink.shown, isEmpty);
    });
  });

  group('notificationContentFromFcm (background isolate)', () {
    test('renders the notification block when present', () {
      final content = notificationContentFromFcm(
        RemoteMessage(
          data: {'conversation_id': 'c1', 'message_id': 'm1', 'sender_name': 'Alice'},
          notification: const RemoteNotification(title: 'Alice', body: 'hey there'),
        ),
      );

      expect(content, isNotNull);
      expect(content!.conversationId, 'c1');
      expect(content.title, 'Alice');
      expect(content.body, 'hey there');
      expect(content.messageId, 'm1');
    });

    test('falls back to the sender name and a generic body for a data-only push', () {
      final content = notificationContentFromFcm(
        RemoteMessage(
          data: {'conversation_id': 'c1', 'message_id': 'm1', 'sender_name': 'Bob'},
        ),
      );

      expect(content!.title, 'Bob');
      expect(content.body, 'New message');
      expect(content.body, isNot(contains('e2ee:v1:')));
    });

    test('ignores a payload with no conversation to route to', () {
      expect(notificationContentFromFcm(RemoteMessage(data: {'message_id': 'm1'})), isNull);
    });
  });

  group('PushRegistration', () {
    test('registers the current token on start and again on refresh', () async {
      final api = _RecordingApi();
      final refresh = StreamController<String>.broadcast();
      final push = PushRegistration(
        api,
        currentToken: () async => 'fid-1',
        onTokenRefresh: refresh.stream,
        retryDelay: (_) => Duration.zero,
      );

      await push.start();
      expect(api.tokens, ['fid-1']);

      refresh.add('fid-2');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.tokens, ['fid-1', 'fid-2']);

      await push.stop();
      await refresh.close();
    });

    test('retries a failed registration before succeeding', () async {
      final api = _RecordingApi()..failuresRemaining = 2;
      final push = PushRegistration(
        api,
        currentToken: () async => 'fid-1',
        onTokenRefresh: const Stream<String>.empty(),
        retryDelay: (_) => Duration.zero,
      );

      await push.start();
      expect(api.attempts, 3);
      expect(api.tokens, ['fid-1']);
    });

    test('does nothing when Firebase is unavailable', () async {
      final api = _RecordingApi();
      final push = PushRegistration(
        api,
        currentToken: () async => null,
        onTokenRefresh: const Stream<String>.empty(),
      );

      await push.start();
      expect(api.attempts, 0);
      expect(api.tokens, isEmpty);
    });
  });
}
