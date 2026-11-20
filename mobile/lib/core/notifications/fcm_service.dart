import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Firebase Cloud Messaging bootstrap.
///
/// Initialization is best-effort: the app stays usable when
/// `google-services.json` is absent (for example in fresh checkouts or in
/// widget tests). Phase 1 wires notification taps to deep links.
abstract final class FcmService {
  @pragma('vm:entry-point')
  static Future<void> backgroundHandler(RemoteMessage message) async {
    await Firebase.initializeApp();
  }

  static Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      await FirebaseMessaging.instance.requestPermission();
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      FirebaseMessaging.onBackgroundMessage(backgroundHandler);
    } catch (error) {
      debugPrint('FCM unavailable: $error');
    }
  }

  /// Returns the FCM registration identifier for this install, or `null` when
  /// Firebase is not configured.
  static Future<String?> currentToken() async {
    try {
      final registration =
          FirebaseMessaging.instance.onRegistered.first;
      await FirebaseMessaging.instance.register();
      return await registration.timeout(const Duration(seconds: 10));
    } catch (error) {
      debugPrint('FCM token unavailable: $error');
      return null;
    }
  }

  static Stream<RemoteMessage> get onForegroundMessage =>
      FirebaseMessaging.onMessage;

  static Stream<String> get onTokenRefresh =>
      FirebaseMessaging.instance.onRegistered;

  static Stream<RemoteMessage> get onNotificationTap =>
      FirebaseMessaging.onMessageOpenedApp;
}
