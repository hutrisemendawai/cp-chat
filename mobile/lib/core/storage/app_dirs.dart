import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves app-owned storage roots with OS backup hygiene.
///
/// On Android, [noBackup] queries `Context.getNoBackupFilesDir()` via the
/// `cpchat/storage` method channel so SQLite partitions live outside Auto Backup
/// and device transfer independently of XML rules. If the platform channel is
/// unavailable (desktop, tests, or plugin error), it falls back to application
/// support storage or a temporary directory in tests.
class AppDirs {
  AppDirs({
    Directory? noBackupDir,
    Directory? cacheDir,
    Directory? documentsDir,
    MethodChannel? channel,
  })  : _noBackupOverride = noBackupDir,
        _cacheOverride = cacheDir,
        _documentsOverride = documentsDir,
        _resolvedNoBackup = noBackupDir,
        _resolvedCache = cacheDir,
        _channel = channel ?? _defaultChannel;

  /// Creates an [AppDirs] pinned to explicit subdirectories under [root] for
  /// deterministic unit and widget tests.
  factory AppDirs.forTesting(Directory root) {
    return AppDirs(
      noBackupDir: Directory(p.join(root.path, 'no_backup')),
      cacheDir: Directory(p.join(root.path, 'cache')),
      documentsDir: Directory(p.join(root.path, 'documents')),
    );
  }

  static const MethodChannel _defaultChannel = MethodChannel('cpchat/storage');
  static final AppDirs _shared = AppDirs();

  final Directory? _noBackupOverride;
  final Directory? _cacheOverride;
  final Directory? _documentsOverride;
  final MethodChannel _channel;
  Directory? _resolvedNoBackup;
  Directory? _resolvedCache;

  /// Synchronously returns the resolved `no_backup` root if [initialize] or
  /// [noBackupDir] has completed (always non-null for [AppDirs.forTesting]).
  Directory? get cachedNoBackupDir => _resolvedNoBackup;

  /// Synchronously returns the resolved `cache` root if [initialize] or
  /// [cacheDir] has completed (always non-null for [AppDirs.forTesting]).
  Directory? get cachedCacheDir => _resolvedCache;

  /// Eagerly resolves and caches the storage roots during startup.
  Future<void> initialize() async {
    await noBackupDir();
    await cacheDir();
  }

  static Future<Directory> noBackup() => _shared.noBackupDir();
  static Future<Directory> cache() => _shared.cacheDir();
  static Future<Directory> documents() => _shared.documentsDir();

  /// Directory excluded from OS cloud backups and device transfers.
  Future<Directory> noBackupDir() async {
    final override = _noBackupOverride;
    if (override != null) {
      await override.create(recursive: true);
      _resolvedNoBackup = override;
      return override;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final path = await _channel.invokeMethod<String>('getNoBackupFilesDir');
        if (path != null && path.isNotEmpty) {
          final dir = Directory(path);
          await dir.create(recursive: true);
          _resolvedNoBackup = dir;
          return dir;
        }
      } on MissingPluginException {
        // Fall through to path_provider / test fallback.
      } on PlatformException catch (error) {
        debugPrint('AppDirs.noBackupDir channel failed: $error');
      }
    }

    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'no_backup'));
      await dir.create(recursive: true);
      _resolvedNoBackup = dir;
      return dir;
    } on MissingPluginException {
      final dir = await _testFallback('no_backup');
      _resolvedNoBackup = dir;
      return dir;
    } catch (_) {
      final dir = await _testFallback('no_backup');
      _resolvedNoBackup = dir;
      return dir;
    }
  }

  /// OS-evictable cache directory for per-account media and upload temps.
  Future<Directory> cacheDir() async {
    final override = _cacheOverride;
    if (override != null) {
      await override.create(recursive: true);
      _resolvedCache = override;
      return override;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final path = await _channel.invokeMethod<String>('getCacheDir');
        if (path != null && path.isNotEmpty) {
          final dir = Directory(path);
          await dir.create(recursive: true);
          _resolvedCache = dir;
          return dir;
        }
      } on MissingPluginException {
        // Fall through.
      } on PlatformException catch (error) {
        debugPrint('AppDirs.cacheDir channel failed: $error');
      }
    }

    try {
      final dir = await getTemporaryDirectory();
      await dir.create(recursive: true);
      _resolvedCache = dir;
      return dir;
    } on MissingPluginException {
      final dir = await _testFallback('cache');
      _resolvedCache = dir;
      return dir;
    } catch (_) {
      final dir = await _testFallback('cache');
      _resolvedCache = dir;
      return dir;
    }
  }

  /// Application documents directory (used only when migrating legacy installs).
  Future<Directory> documentsDir() async {
    final override = _documentsOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      await dir.create(recursive: true);
      return dir;
    } on MissingPluginException {
      return _testFallback('documents');
    } catch (_) {
      return _testFallback('documents');
    }
  }

  Future<Directory> _testFallback(String leaf) async {
    final dir = Directory(p.join(Directory.systemTemp.path, 'cpchat_app_dirs', leaf));
    await dir.create(recursive: true);
    return dir;
  }
}
