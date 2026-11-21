import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Crash reporting for release builds.
///
/// Wired up next to [FcmService]: both depend on Firebase being configured, so a
/// fresh checkout without `google-services.json` simply runs without either.
///
/// In release mode Flutter's framework errors, uncaught async errors, and
/// platform exceptions are forwarded to Crashlytics. In debug they are printed
/// only, so local runs never pollute the production dashboard. Message bodies
/// are never attached to an error report; E2EE ciphertext stays on the device.
abstract final class CrashReporter {
  static bool _initialized = false;

  static Future<void> initialize() async {
    // Crashlytics only collects in release; skip the work elsewhere.
    if (kDebugMode) return;
    if (Firebase.apps.isEmpty) return;

    try {
      final crashlytics = FirebaseCrashlytics.instance;
      await crashlytics.setCrashlyticsCollectionEnabled(true);

      FlutterError.onError = (details) {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      _initialized = true;
    } catch (error) {
      debugPrint('Crashlytics unavailable: $error');
      _initialized = false;
    }
  }

  static bool get isEnabled => _initialized;

  /// Logs a non-fatal error. Use for recoverable failures that still need to be
  /// visible (E2EE decrypt errors, reconnect failures) without crashing.
  static void record(Object error, StackTrace? stack, {String? reason}) {
    if (!_initialized) return;
    FirebaseCrashlytics.instance.recordError(error, stack, reason: reason, fatal: false);
  }
}
