import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import 'fcm_service.dart';

/// Registers this install for push delivery once a session exists and keeps the
/// registration current when Firebase rotates the installation id.
class PushRegistration {
  PushRegistration(this._api);

  final ApiClient _api;
  StreamSubscription<String>? _refresh;

  Future<void> start() async {
    final fid = await FcmService.currentToken();
    if (fid != null) {
      try {
        await _api.registerFcmToken(fid);
      } catch (error) {
        debugPrint('FCM registration failed: $error');
      }
    }

    _refresh ??= FcmService.onTokenRefresh.listen((next) async {
      try {
        await _api.registerFcmToken(next);
      } catch (error) {
        debugPrint('FCM refresh registration failed: $error');
      }
    });
  }

  Future<void> stop() async {
    await _refresh?.cancel();
    _refresh = null;
  }
}
