import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Where a message notification is delivered. The [MessageNotifier] depends on
/// this instead of the plugin directly so its rules stay unit-testable.
abstract class MessageNotificationSink {
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
  });
}

/// Android notification-tray integration for incoming messages.
///
/// A foreground Android app paints no tray notification on its own, so live
/// WebSocket messages (and foreground FCM pushes) are surfaced here. The
/// channel, the Android 13+ permission request, and tap routing are all
/// independent of Firebase, which keeps notifications working on self-hosted
/// LAN builds that ship without `google-services.json`.
class LocalNotificationService implements MessageNotificationSink {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// High-importance channel. The backend's default FCM channel targets the
  /// same id so a background push and a foreground banner look identical.
  static const String channelId = 'cpchat_messages';
  static const String channelName = 'Messages';

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController<String>.broadcast();

  bool _initialized = false;
  String? _coldStartConversationId;

  /// Emits the `conversation_id` of a tapped notification.
  Stream<String> get onNotificationTap => _taps.stream;

  /// The `conversation_id` of the notification that cold-started the app, if
  /// any. Read after [initialize] to route straight into the right chat.
  String? get coldStartConversationId => _coldStartConversationId;

  Future<void> initialize() async {
    if (_initialized) return;
    // Only Android settings are supplied, and the plugin asserts on the target
    // platform's settings during `flutter test` (Linux). Skip cleanly there.
    if (defaultTargetPlatform != TargetPlatform.android) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: 'Incoming chat messages',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final payload = launch?.notificationResponse?.payload;
      if (payload != null && payload.isNotEmpty) {
        _coldStartConversationId = payload;
      }
    }
    _initialized = true;
  }

  /// Prompts Android 13+ (API 33+) users for the runtime `POST_NOTIFICATIONS`
  /// permission. A no-op on other platforms and without a configured channel.
  Future<void> requestPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }

  @override
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      id: _notificationId(conversationId),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Incoming chat messages',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      ),
      payload: conversationId,
    );
  }

  /// Clears the notification shown for one conversation (its chat was opened).
  Future<void> cancelForConversation(String conversationId) async {
    if (!_initialized) return;
    await _plugin.cancel(id: _notificationId(conversationId));
  }

  /// Clears every notification (on sign-out).
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) _taps.add(payload);
  }

  /// One stable id per conversation so a newer message replaces the previous
  /// banner for the same chat instead of stacking banners.
  int _notificationId(String conversationId) => conversationId.hashCode & 0x7fffffff;

  Future<void> dispose() => _taps.close();
}
