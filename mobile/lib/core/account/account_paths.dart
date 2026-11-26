import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/app_dirs.dart';

/// Filesystem paths owned by one local account partition.
///
/// Durable data (SQLite DB + WAL/SHM) lives under `<noBackupDir>/accounts/<id>/`
/// so Android excludes it from Auto Backup and device transfer independently of
/// manifest XML rules. Regenerable data (media cache and upload temps) lives
/// under `<cacheDir>/accounts/<id>/`.
class AccountPaths {
  const AccountPaths({
    required this.accountId,
    required this.noBackupRoot,
    required this.cacheRoot,
  });

  final String accountId;
  final Directory noBackupRoot;
  final Directory cacheRoot;

  /// Resolves partition paths from [dirs] for [accountId].
  static Future<AccountPaths> resolve(String accountId, AppDirs dirs) async {
    final noBackup = await dirs.noBackupDir();
    final cache = await dirs.cacheDir();
    return AccountPaths(
      accountId: accountId,
      noBackupRoot: noBackup,
      cacheRoot: cache,
    );
  }

  /// Durable account partition directory (`<noBackupRoot>/accounts/<id>`).
  Directory get partitionDir => Directory(p.join(noBackupRoot.path, 'accounts', accountId));

  /// Primary SQLite database file (`cpchat_<id>.sqlite`).
  File get dbFile => File(p.join(partitionDir.path, 'cpchat_$accountId.sqlite'));

  /// Primary SQLite file plus WAL/SHM/journal sidecars to remove on wipe.
  List<File> get dbFiles => [
        dbFile,
        File('${dbFile.path}-wal'),
        File('${dbFile.path}-shm'),
        File('${dbFile.path}-journal'),
      ];

  /// Account-scoped cache root (`<cacheRoot>/accounts/<id>`).
  Directory get cacheDir => Directory(p.join(cacheRoot.path, 'accounts', accountId));

  /// Per-account media cache directory (`<cacheRoot>/accounts/<id>/media`).
  Directory get mediaCacheDir => Directory(p.join(cacheDir.path, 'media'));

  /// Per-account upload temp directory (`<cacheRoot>/accounts/<id>/tmp`).
  Directory get uploadTmpDir => Directory(p.join(cacheDir.path, 'tmp'));

  /// Legacy single-file DB files created by builds prior to partitioning.
  static List<File> legacyDbFiles(Directory documentsDir) {
    final base = p.join(documentsDir.path, 'cp_chat.sqlite');
    return [
      File(base),
      File('$base-wal'),
      File('$base-shm'),
      File('$base-journal'),
    ];
  }

  /// Deletes the account's upload temp directory (called on logout).
  Future<void> clearUploadTmp() async {
    try {
      if (await uploadTmpDir.exists()) {
        await uploadTmpDir.delete(recursive: true);
      }
    } catch (_) {
      // Best effort: temp files are OS-evictable.
    }
  }
}
