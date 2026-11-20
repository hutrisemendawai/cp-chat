import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Firebase Cloud Messaging bootstrap.
///
/// Initialization is best-effort: the app stays usable when
/// `google-services.json` is absent (for example in fresh checkouts or in
/// widget tests), which keeps CI and emulator runs free of Firebase setup.
@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

abstract final class FcmService {
  static bool _initialized = false;

  static Future<void> initialize() async {
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
      FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
      _initialized = true;
    } catch (error) {
      debugPrint('FCM unavailable: $error');
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
      debugPrint('FCM registration unavailable: $error');
      return null;
    }
  }

  static Stream<String> get onTokenRefresh => FirebaseMessaging.instance.onRegistered;

  /// Fires when the user taps a notification while the app is backgrounded.
  static Stream<RemoteMessage> get onNotificationTap =>
      FirebaseMessaging.onMessageOpenedApp;

  /// The notification that launched the app from a terminated state, if any.
  static Future<RemoteMessage?> initialMessage() =>
      FirebaseMessaging.instance.getInitialMessage();
}
