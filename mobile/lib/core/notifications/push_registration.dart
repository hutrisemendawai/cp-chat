import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
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
    bool Function()? isAvailable,
    Duration Function(int attempt)? retryDelay,
    this.logger,
  })  : _currentToken = currentToken ?? FcmService.currentToken,
        _refreshStream = onTokenRefresh,
        _available = isAvailable,
        _retryDelay = retryDelay ?? _defaultRetryDelay;

  final ApiClient _api;

  /// A first attempt can land before the freshly-issued access token is usable
  /// on a flaky link, so registration is retried a few times with backoff.
  final int maxAttempts;
  final Future<String?> Function() _currentToken;

  /// Resolved lazily: reading [FcmService.onTokenRefresh] touches the Firebase
  /// plugin, which must not happen until a registration actually starts.
  final Stream<String>? _refreshStream;
  final bool Function()? _available;
  final Duration Function(int attempt) _retryDelay;
  final AppLogger? logger;

  StreamSubscription<String>? _refresh;
  Future<void>? _inFlight;
  bool _started = false;
  bool _registered = false;

  /// Whether this session has successfully registered a token with the server.
  bool get isRegistered => _registered;

  bool _isAvailable() =>
      _available?.call() ?? (_refreshStream != null || FcmService.isAvailable);

  Future<void> start() async {
    _started = true;
    _registered = false;
    if (!_isAvailable()) return;

    await _registerCurrent();
    if (!_started) return;
    _refresh ??= (_refreshStream ?? FcmService.onTokenRefresh)
        .listen((fid) => unawaited(_register(fid)));
  }

  /// Retries initial FID registration after an offline or timed-out launch once
  /// connectivity returns (for example when the WebSocket reconnects).
  Future<void> ensureRegistered() async {
    if (!_started || _registered || !_isAvailable()) return;
    await _registerCurrent();
  }

  Future<void> stop() async {
    _started = false;
    await _refresh?.cancel();
    _refresh = null;
  }

  /// Unregisters this device's push token on explicit logout so a signed-out
  /// install stops receiving alerts for the previous account. Bounded so a
  /// slow or unreachable server never stalls logout.
  Future<void> unregister({Duration timeout = const Duration(seconds: 3)}) async {
    if (_started) await stop();
    if (!_registered && !_isAvailable()) return;
    try {
      await _api.unregisterFcmToken().timeout(timeout);
    } finally {
      _registered = false;
    }
  }

  Future<void> _registerCurrent() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = () async {
      final fid = await _currentToken();
      if (!_started) return;
      await _register(fid);
    }();
    _inFlight = run;
    return run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
  }

  Future<void> _register(String? fid) async {
    if (fid == null || fid.isEmpty) return;
    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      if (!_started) return;
      try {
        await _api.registerFcmToken(fid);
        _registered = true;
        logger?.info('fcm', 'push token registered');
        return;
      } catch (error) {
        if (attempt >= maxAttempts) {
          if (logger != null) {
            logger!.warn(
              'fcm',
              'FCM registration failed after $attempt attempts',
              meta: {'attempts': attempt, 'error': error.toString()},
            );
          } else {
            debugPrint('FCM registration failed after $attempt attempts: $error');
          }
          return;
        }
        await Future<void>.delayed(_retryDelay(attempt));
      }
    }
  }

  static Duration _defaultRetryDelay(int attempt) => Duration(seconds: attempt);
}
