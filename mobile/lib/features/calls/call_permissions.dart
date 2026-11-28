import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

enum CallPermissionOutcome {
  granted,
  denied,
  permanentlyDenied,
}

@immutable
class CallPermissionResult {
  const CallPermissionResult({
    required this.microphone,
    this.camera = CallPermissionOutcome.granted,
  });

  final CallPermissionOutcome microphone;
  final CallPermissionOutcome camera;

  bool get hasMicrophone => microphone == CallPermissionOutcome.granted;
  bool get hasCamera => camera == CallPermissionOutcome.granted;
  bool get anyPermanentlyDenied =>
      microphone == CallPermissionOutcome.permanentlyDenied ||
      camera == CallPermissionOutcome.permanentlyDenied;
}

/// Runtime permission gateway for voice and video calls.
///
/// Wraps `permission_handler` so call flows and Android 14+ camera FGS upgrades
/// never trigger SecurityExceptions and permanently-denied states prompt the
/// user cleanly to open Android app settings.
class CallPermissionService {
  const CallPermissionService();

  Future<CallPermissionResult> ensureForVoice() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const CallPermissionResult(microphone: CallPermissionOutcome.granted);
    }
    final mic = await _request(Permission.microphone);
    // Request notification permission best-effort on Android 13+ for the FGS bar.
    await _request(Permission.notification);
    return CallPermissionResult(microphone: mic);
  }

  Future<CallPermissionResult> ensureForVideo() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const CallPermissionResult(
        microphone: CallPermissionOutcome.granted,
        camera: CallPermissionOutcome.granted,
      );
    }
    final mic = await _request(Permission.microphone);
    final cam = await _request(Permission.camera);
    await _request(Permission.notification);
    return CallPermissionResult(microphone: mic, camera: cam);
  }

  Future<CallPermissionOutcome> ensureCameraForUpgrade() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return CallPermissionOutcome.granted;
    }
    return _request(Permission.camera);
  }

  Future<CallPermissionOutcome> ensureBluetoothConnect() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return CallPermissionOutcome.granted;
    }
    return _request(Permission.bluetoothConnect);
  }

  Future<bool> openSettings() => openAppSettings();

  Future<CallPermissionOutcome> _request(Permission permission) async {
    try {
      final status = await permission.request();
      if (status.isGranted || status.isLimited) {
        return CallPermissionOutcome.granted;
      }
      if (status.isPermanentlyDenied) {
        return CallPermissionOutcome.permanentlyDenied;
      }
      return CallPermissionOutcome.denied;
    } catch (_) {
      return CallPermissionOutcome.denied;
    }
  }
}
