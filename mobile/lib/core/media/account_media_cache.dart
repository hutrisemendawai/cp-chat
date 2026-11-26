import 'dart:io';

import 'package:file/file.dart' as f;
import 'package:file/local.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

/// Namespaced cache key so neither disk nor memory caches can collide across
/// accounts even if two accounts share access to the same media object key.
String accountMediaCacheKey(String? accountId, String objectKey) =>
    accountId == null || accountId.isEmpty ? objectKey : '$accountId:$objectKey';

/// Clears Flutter's process-wide decoded image cache (called on logout,
/// account switch, and L1/L2 clear).
void evictMemoryImageCache() {
  try {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  } catch (_) {
    // PaintingBinding may not be initialized in pure Dart unit tests.
  }
}

/// Custom [FileSystem] for [CacheManager] rooted strictly inside an account's
/// `<cacheRoot>/accounts/<accountId>/media/` directory.
class _AccountCacheFileSystem implements FileSystem {
  _AccountCacheFileSystem(this._mediaDir);

  final Directory _mediaDir;
  static const LocalFileSystem _fs = LocalFileSystem();

  @override
  Future<f.File> createFile(String name) async {
    final dir = _fs.directory(_mediaDir.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.childFile(name);
  }
}

/// Per-account [CacheManager] storing cached image bytes and metadata strictly
/// inside the account's own cache directory.
class AccountMediaCache extends CacheManager {
  AccountMediaCache({
    required this.accountId,
    required this.mediaDir,
  }) : super(
          Config(
            'cpchat_media_$accountId',
            stalePeriod: const Duration(days: 7),
            maxNrOfCacheObjects: 200,
            repo: JsonCacheInfoRepository(
              path: p.join(mediaDir.path, 'cache_info.json'),
            ),
            fileSystem: _AccountCacheFileSystem(mediaDir),
          ),
        );

  final String accountId;
  final Directory mediaDir;

  /// Empties both the CacheManager database/files and the underlying directory.
  Future<void> clearAccountCache() async {
    try {
      await emptyCache();
    } catch (_) {
      // Fall back to direct directory cleanup below.
    }
    try {
      if (await mediaDir.exists()) {
        await mediaDir.delete(recursive: true);
      }
    } catch (_) {
      // Best effort.
    }
    evictMemoryImageCache();
  }
}
