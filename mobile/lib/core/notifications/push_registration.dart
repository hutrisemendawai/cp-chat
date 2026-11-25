import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import 'fcm_service.dart';

/// Registers this install for push delivery once a session exists and keeps the
/// registration current when Firebase rotates the installation id.
///
/// The token source is injectable so the registration lifecycle can be unit
/// tested without a live Firebase project.
class PushRegistration {
  PushRegistration(
    this._api, {
    this.maxAttempts = 3,
    Future<String?> Function()? currentToken,
    Stream<String>? onTokenRefresh,
    Duration Function(int attempt)? retryDelay,
  })  : _currentToken = currentToken ?? FcmService.currentToken,
        _refreshStream = onTokenRefresh,
        _retryDelay = retryDelay ?? _defaultRetryDelay;

  final ApiClient _api;

  /// A first attempt can land before the freshly-issued access token is usable
  /// on a flaky link, so registration is retried a few times with backoff.
  final int maxAttempts;
  final Future<String?> Function() _currentToken;

  /// Resolved lazily: reading [FcmService.onTokenRefresh] touches the Firebase
  /// plugin, which must not happen until a registration actually starts.
  final Stream<String>? _refreshStream;
  final Duration Function(int attempt) _retryDelay;

  StreamSubscription<String>? _refresh;

  Future<void> start() async {
    await _register(await _currentToken());
    _refresh ??= (_refreshStream ?? FcmService.onTokenRefresh)
        .listen((fid) => unawaited(_register(fid)));
  }

  Future<void> stop() async {
    await _refresh?.cancel();
    _refresh = null;
  }

  Future<void> _register(String? fid) async {
    if (fid == null) return;
    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        await _api.registerFcmToken(fid);
        return;
      } catch (error) {
        if (attempt >= maxAttempts) {
          debugPrint('FCM registration failed after $attempt attempts: $error');
          return;
        }
        await Future<void>.delayed(_retryDelay(attempt));
      }
    }
  }

  static Duration _defaultRetryDelay(int attempt) => Duration(seconds: attempt);
}
