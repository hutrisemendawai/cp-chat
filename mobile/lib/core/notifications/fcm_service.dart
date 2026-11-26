import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'local_notification_service.dart';

/// The tray content derived from an FCM payload.
typedef FcmNotificationContent = ({
  String conversationId,
  String title,
  String body,
  String? messageId,
});

/// Maps a push to tray content, or `null` when it carries no conversation to
/// route to. The body falls back to `New message` because the headless isolate
/// cannot run E2EE decryption, and it never carries ciphertext.
FcmNotificationContent? notificationContentFromFcm(RemoteMessage message) {
  final conversationId = message.data['conversation_id']?.toString() ?? '';
  if (conversationId.isEmpty) return null;
  final senderName = message.data['sender_name']?.toString();
  return (
    conversationId: conversationId,
    title: message.notification?.title ?? senderName ?? 'New message',
    body: message.notification?.body ?? 'New message',
    messageId: message.data['message_id']?.toString(),
  );
}

/// Runs in a headless isolate when a push arrives with no UI. Riverpod providers
/// and UI state do not exist here, so Firebase and the notification plugin are
/// re-initialized from scratch. A push that also carries a `notification` block
/// is already painted by Android, so it is left alone to avoid a duplicate
/// banner; a data-only push is surfaced from here instead.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.notification != null) return;

  final content = notificationContentFromFcm(message);
  if (content == null) return;

  final notifications = LocalNotificationService();
  await notifications.initialize();
  await notifications.showMessageNotification(
    conversationId: content.conversationId,
    title: content.title,
    body: content.body,
    messageId: content.messageId,
  );
}

/// Firebase Cloud Messaging bootstrap.
///
/// Initialization is best-effort: the app stays usable when
/// `google-services.json` is absent (for example in fresh checkouts or in
/// widget tests), which keeps CI and emulator runs free of Firebase setup.
abstract final class FcmService {
  static bool _initialized = false;
  static AppLogger? _logger;

  static Future<void> initialize({AppLogger? logger}) async {
    if (logger != null) _logger = logger;
    try {
      await Firebase.initializeApp();
      await FirebaseMessaging.instance.requestPermission();
      // Android 13+ needs the runtime POST_NOTIFICATIONS permission; the
      // manifest declares it.
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      _initialized = true;
      _logger?.info('fcm', 'FCM initialized');
    } catch (error) {
      final message =
          'FCM unavailable: Firebase is not configured '
          '(missing google-services.json or invalid options): $error';
      if (_logger != null) {
        _logger!.warn('fcm', message, meta: {'error': error.toString()});
      } else {
        debugPrint(message);
      }
      _initialized = false;
    }
  }

  static bool get isAvailable => _initialized;

  /// Returns the Firebase Installation ID (FID) for this install, or `null`
  /// when Firebase is not configured.
  ///
  /// `register()` + `onRegistered` is the non-deprecated path; the legacy
  /// `getToken()` registration token is not used because the backend addresses
  /// FCM sends by FID.
  static Future<String?> currentToken() async {
    if (!_initialized) return null;
    try {
      final registered = FirebaseMessaging.instance.onRegistered.first;
      await FirebaseMessaging.instance.register();
      return await registered.timeout(const Duration(seconds: 10));
    } catch (error) {
      if (_logger != null) {
        _logger!.warn(
          'fcm',
          'FCM registration unavailable',
          meta: {'error': error.toString()},
        );
      } else {
        debugPrint('FCM registration unavailable: $error');
      }
      return null;
    }
  }

  static Stream<String> get onTokenRefresh =>
      _initialized ? FirebaseMessaging.instance.onRegistered : const Stream<String>.empty();

  /// Fires when the user taps a notification while the app is backgrounded.
  static Stream<RemoteMessage> get onNotificationTap =>
      FirebaseMessaging.onMessageOpenedApp;

  /// Fires for messages received while the app is foregrounded. Android does
  /// not paint a tray notification for these, so the app surfaces one itself.
  static Stream<RemoteMessage> get onForegroundMessage => FirebaseMessaging.onMessage;

  /// The notification that launched the app from a terminated state, if any.
  static Future<RemoteMessage?> initialMessage() =>
      FirebaseMessaging.instance.getInitialMessage();
}
