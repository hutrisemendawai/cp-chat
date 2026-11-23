import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../network/api_client.dart';

/// Severity of a client diagnostic entry. Mirrors the backend log levels so the
/// dashboard can filter mobile entries with the same chips as server ones.
enum AppLogLevel { debug, info, warn, error }

/// One buffered diagnostic entry.
@immutable
class AppLogEntry {
  const AppLogEntry({
    required this.ts,
    required this.level,
    required this.tag,
    required this.message,
    this.meta,
  });

  final DateTime ts;
  final AppLogLevel level;
  final String tag;
  final String message;
  final Map<String, Object?>? meta;

  String get levelName => level.name;

  Map<String, Object?> toJson() => {
        'ts': ts.toUtc().millisecondsSinceEpoch,
        'level': levelName,
        'tag': tag,
        'message': message,
        if (meta != null && meta!.isNotEmpty) 'meta': meta,
      };

  /// Wire shape for `POST /api/v1/logs/client`.
  Map<String, Object?> toRequestJson() => toJson();
}

/// Client-side diagnostics with a bounded in-memory history.
///
/// Every `warn`/`error` is also forwarded to `POST /api/v1/logs/client` so the
/// server timeline shows what the phone saw. Forwarding is fire-and-forget and
/// guarded against re-entry: a logging call can never throw, recurse, or keep a
/// caller waiting on the network.
class AppLogger {
  AppLogger({
    this.maxEntries = 300,
    this.retention = const Duration(hours: 1),
    ApiClient? api,
    DateTime Function()? clock,
  })  :
        // ignore: prefer_initializing_formals
        _api = api,
        _clock = clock ?? DateTime.now;

  final int maxEntries;
  final Duration retention;
  final DateTime Function() _clock;

  ApiClient? _api;
  final List<AppLogEntry> _buffer = [];
  final List<AppLogEntry> _pending = [];
  bool _draining = false;

  /// Read-only snapshot of the retained entries, oldest first.
  List<AppLogEntry> get entries => List.unmodifiable(_buffer);

  /// Attaches the API client used for forwarding. The logger is created before
  /// the network stack during bootstrap, so this is wired up separately.
  void attach(ApiClient api) => _api = api;

  void debug(String tag, String message, {Map<String, Object?>? meta}) =>
      _add(AppLogLevel.debug, tag, message, meta);

  void info(String tag, String message, {Map<String, Object?>? meta}) =>
      _add(AppLogLevel.info, tag, message, meta);

  void warn(String tag, String message, {Map<String, Object?>? meta}) =>
      _add(AppLogLevel.warn, tag, message, meta);

  void error(String tag, String message, {Map<String, Object?>? meta}) =>
      _add(AppLogLevel.error, tag, message, meta);

  /// Records an exception. The message is kept short and stack traces are not
  /// forwarded — they are large and rarely useful in the shared timeline.
  void exception(String tag, Object error, {StackTrace? stack, Map<String, Object?>? meta}) {
    final detail = <String, Object?>{...?meta, 'error': error.toString()};
    if (stack != null && kDebugMode) detail['stack'] = stack.toString().split('\n').take(5).join('\n');
    _add(AppLogLevel.error, tag, error.toString(), detail);
  }

  /// Records a Dio failure with the connection-relevant fields only.
  void networkError(String tag, DioException error) {
    final request = error.requestOptions;
    _add(AppLogLevel.error, tag, 'network error: ${error.type.name}', {
      'method': request.method,
      'path': request.path,
      if (error.response?.statusCode != null) 'status_code': error.response!.statusCode,
      if (error.message != null) 'detail': error.message,
    });
  }

  void clear() => _buffer.clear();

  void _add(AppLogLevel level, String tag, String message, Map<String, Object?>? meta) {
    final entry = AppLogEntry(
      ts: _clock(),
      level: level,
      tag: tag,
      message: _redact(message),
      meta: _redactMeta(meta),
    );

    _buffer.add(entry);
    _trim();
    if (kDebugMode) debugPrint('[${entry.levelName}] ${entry.tag}: ${entry.message}');

    if (level == AppLogLevel.warn || level == AppLogLevel.error) {
      _forward(entry);
    }
  }

  /// Drops entries past the count cap and past the retention window.
  void _trim() {
    final cutoff = _clock().subtract(retention);
    _buffer.removeWhere((entry) => entry.ts.isBefore(cutoff));
    if (_buffer.length > maxEntries) {
      _buffer.removeRange(0, _buffer.length - maxEntries);
    }
  }

  /// Queues one entry for delivery. At most one request is in flight at a time;
  /// entries that arrive meanwhile wait their turn instead of being dropped.
  ///
  /// The forwarding call deliberately bypasses this logger: a failure must not
  /// produce another log entry, which would start an endless retry loop.
  void _forward(AppLogEntry entry) {
    if (_api == null) return;
    _pending.add(entry);
    if (_draining) return;

    _draining = true;
    unawaited(_drain());
  }

  /// Sends queued entries until the queue is empty or the client goes away.
  /// A failed submission is dropped rather than retried: a down server would
  /// otherwise accumulate an unbounded backlog.
  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final api = _api;
        if (api == null) return;
        final entry = _pending.removeAt(0);
        try {
          await api.logClientEntry(entry);
        } catch (_) {
          // Best effort; the entry stays in the local ring buffer.
        }
      }
    } finally {
      _draining = false;
    }
  }

  static String _redact(String value) {
    // A bearer token or E2EE envelope can end up in an exception message; the
    // server redacts too, but nothing sensitive should leave the device.
    return value
        .replaceAll(RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'), '[redacted]')
        .replaceAll(RegExp(r'e2ee:v1:\S+'), '[redacted]');
  }

  static Map<String, Object?>? _redactMeta(Map<String, Object?>? meta) {
    if (meta == null) return null;
    final safe = <String, Object?>{};
    for (final entry in meta.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains('password') ||
          key.contains('token') ||
          key.contains('secret') ||
          key == 'authorization' ||
          key == 'content') {
        safe[entry.key] = '[redacted]';
        continue;
      }
      final value = entry.value;
      safe[entry.key] = value is String ? _redact(value) : value;
    }
    return safe;
  }
}
