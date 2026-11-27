import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Cross-isolate and cross-process exclusive lock for an account partition.
///
/// Coordinates SQLite and `acct.<id>.e2ee_sessions` access between the main
/// Flutter isolate (`SessionLifecycle._start`) and any headless FCM background
/// isolate (`BackgroundPushHandler`).
///
/// Uses atomic `O_CREAT | O_EXCL` lock-file creation (`File.create(exclusive: true)`)
/// rather than POSIX `fcntl` locking because on Android the main isolate and
/// `FLTFireBGExecutor` background isolate can run inside the **same** OS
/// process, where `fcntl` locks do not exclude two threads/isolates of one PID.
///
/// Stale locks left behind by an OS `SIGKILL` are recovered automatically:
/// - Immediately if the recorded PID differs from the current process and
///   `/proc/<pid>` no longer exists (Linux/Android).
/// - Otherwise after [staleAfter] (default 30 seconds).
class PartitionLock {
  PartitionLock._();

  static const String lockFileName = '.partition.lock';
  static const Duration defaultTimeout = Duration(seconds: 6);
  static const Duration defaultStaleAfter = Duration(seconds: 30);
  static const Duration _pollInterval = Duration(milliseconds: 30);
  static const Uuid _uuid = Uuid();

  /// Per-path in-isolate mutex chains so concurrent callers within one isolate
  /// queue cleanly without polling.
  static final Map<String, Future<void>> _inIsolate = {};

  /// Runs [action] while holding the exclusive lock for [partitionDir].
  ///
  /// Throws a [TimeoutException] if the lock cannot be acquired within
  /// [timeout].
  static Future<T> withLock<T>(
    Directory partitionDir,
    Future<T> Function() action, {
    Duration timeout = defaultTimeout,
    Duration staleAfter = defaultStaleAfter,
    String fileName = lockFileName,
  }) async {
    final lockPath = p.join(partitionDir.path, fileName);
    final prev = _inIsolate[lockPath] ?? Future<void>.value();
    final done = Completer<void>();
    _inIsolate[lockPath] = done.future;

    try {
      await prev;
      return await _acquireFileLockAndRun(
        partitionDir,
        File(lockPath),
        action,
        timeout: timeout,
        staleAfter: staleAfter,
      );
    } finally {
      done.complete();
      if (identical(_inIsolate[lockPath], done.future)) {
        _inIsolate.remove(lockPath);
      }
    }
  }

  static Future<T> _acquireFileLockAndRun<T>(
    Directory partitionDir,
    File lockFile,
    Future<T> Function() action, {
    required Duration timeout,
    required Duration staleAfter,
  }) async {
    if (!await partitionDir.exists()) {
      await partitionDir.create(recursive: true);
    }

    final token = '$pid:${DateTime.now().millisecondsSinceEpoch}:${_uuid.v4()}';
    final deadline = DateTime.now().add(timeout);

    while (true) {
      try {
        await lockFile.create(exclusive: true);
        await lockFile.writeAsString(token, flush: true);
        break;
      } on PathExistsException {
        if (await _reclaimIfStale(lockFile, staleAfter)) {
          continue;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Timed out acquiring partition lock ${lockFile.path}',
            timeout,
          );
        }
        await Future<void>.delayed(_pollInterval);
      } on FileSystemException {
        if (await _reclaimIfStale(lockFile, staleAfter)) {
          continue;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Timed out acquiring partition lock ${lockFile.path}',
            timeout,
          );
        }
        await Future<void>.delayed(_pollInterval);
      }
    }

    try {
      return await action();
    } finally {
      await _release(lockFile, token);
    }
  }

  static Future<bool> _reclaimIfStale(File lockFile, Duration staleAfter) async {
    try {
      if (!await lockFile.exists()) return true;
      final stat = await lockFile.stat();
      final age = DateTime.now().difference(stat.modified);
      if (age >= staleAfter) {
        return await _reclaimAtomically(lockFile);
      }

      if (Platform.isLinux || Platform.isAndroid) {
        final raw = (await lockFile.readAsString()).trim();
        final colon = raw.indexOf(':');
        if (colon > 0) {
          final ownerPid = int.tryParse(raw.substring(0, colon));
          if (ownerPid != null && ownerPid != pid) {
            if (!await Directory('/proc/$ownerPid').exists()) {
              return await _reclaimAtomically(lockFile);
            }
          }
        }
      }
    } catch (_) {
      // Lock disappeared or is mid-write; retry cleanly.
    }
    return false;
  }

  static Future<bool> _reclaimAtomically(File lockFile) async {
    final reclaimPath = '${lockFile.path}.reclaim.${_uuid.v4()}';
    try {
      final moved = await lockFile.rename(reclaimPath);
      await _deleteQuietly(moved);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _release(File lockFile, String token) async {
    try {
      if (!await lockFile.exists()) return;
      final current = await lockFile.readAsString();
      if (current == token) {
        await lockFile.delete();
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
