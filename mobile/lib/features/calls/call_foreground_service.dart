import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Typed Dart bridge to `CallForegroundService.kt` and lock-screen / proximity
/// wake-lock helpers registered on `MainActivity.kt`.
///
/// Cleanly no-ops on non-Android platforms (including host-side unit tests).
class CallForegroundServiceBridge {
  CallForegroundServiceBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  static const String _channelName = 'com.cpchat.mobile/call_service';

  final MethodChannel _channel;
  VoidCallback? onHangupPressed;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onHangupPressed') {
      onHangupPressed?.call();
    }
  }

  Future<void> start({
    required String title,
    String subtitle = 'Tap to return to call',
    bool withCamera = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': title,
        'subtitle': subtitle,
        'withCamera': withCamera,
      });
    } on MissingPluginException {
      // Ignored in tests / unsupported hosts.
    } catch (error) {
      debugPrint('CallForegroundService start failed: $error');
    }
  }

  Future<void> update({
    required String title,
    String subtitle = 'Tap to return to call',
    bool withCamera = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title,
        'subtitle': subtitle,
        'withCamera': withCamera,
      });
    } on MissingPluginException {
      // Ignored in tests / unsupported hosts.
    } catch (error) {
      debugPrint('CallForegroundService update failed: $error');
    }
  }

  Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Ignored in tests / unsupported hosts.
    } catch (error) {
      debugPrint('CallForegroundService stop failed: $error');
    }
  }

  Future<void> setLockScreenVisible(bool visible) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setLockScreenVisible', {
        'visible': visible,
      });
    } on MissingPluginException {
      // Ignored in tests / unsupported hosts.
    } catch (error) {
      debugPrint('setLockScreenVisible failed: $error');
    }
  }

  Future<void> setProximityWakeLock(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setProximityWakeLock', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Ignored in tests / unsupported hosts.
    } catch (error) {
      debugPrint('setProximityWakeLock failed: $error');
    }
  }

  void dispose() {
    onHangupPressed = null;
    if (defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler(null);
    }
  }
}
