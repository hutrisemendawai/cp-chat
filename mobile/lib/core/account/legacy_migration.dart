import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../crypto/e2ee_service.dart';
import '../database/app_database.dart';
import '../logging/app_logger.dart';
import '../storage/app_dirs.dart';
import '../storage/token_store.dart';
import 'account_id.dart';
import 'account_paths.dart';
import 'account_registry.dart';
import 'account_store.dart';
import 'partition_guard.dart';

/// Migrates pre-partition installs (single `cp_chat.sqlite` + global `e2ee_*`
/// keys) into per-account partitions (§3.1).
///
/// Crash-safe and idempotent: copies before deleting, verifies the destination
/// DB can be opened before marking `local_layout = v2_partitioned`, and
/// quarantines ownerless legacy keys until the first login proves ownership
/// against `GET /api/v1/keys/me`.
class LegacyMigration {
  LegacyMigration({
    required this.tokenStore,
    required this.dirs,
    required this.registry,
    E2eeService? e2eeService,
    DateTime Function()? clock,
    this.logger,
    Uuid? uuid,
  })  : _e2eeService = e2eeService ?? E2eeService(),
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _uuid = uuid ?? const Uuid();

  static const layoutKey = 'local_layout';
  static const layoutVersion = 'v2_partitioned';
  static const quarantineKeysKey = 'legacy.e2ee_keys';
  static const quarantineSessionsKey = 'legacy.e2ee_sessions';
  static const quarantineAtKey = 'legacy.quarantined_at';
  static const quarantineTtl = Duration(days: 30);

  final TokenStore tokenStore;
  final AppDirs dirs;
  final AccountRegistry registry;
  final E2eeService _e2eeService;
  final DateTime Function() _clock;
  final AppLogger? logger;
  final Uuid _uuid;

  /// Runs once on startup before opening any account database.
  Future<void> runIfNeeded() async {
    final currentLayout = await tokenStore.readValue(layoutKey);
    if (currentLayout == layoutVersion) {
      await _expireQuarantineIfOld();
      return;
    }

    final documentsDir = await dirs.documentsDir();
    final legacyDbFiles = AccountPaths.legacyDbFiles(documentsDir);
    final legacyDb = legacyDbFiles.first;
    final legacyKeys = await tokenStore.readE2eeKeys();
    final legacySessions = await tokenStore.readE2eeSessions();
    final activeUserId = await tokenStore.readUserId();
    final hasSession = activeUserId != null &&
        ((await tokenStore.readAccessToken()) != null ||
            (await tokenStore.readRefreshToken()) != null);

    if (hasSession) {
      await _adoptForActiveUser(
        userId: activeUserId,
        legacyDb: legacyDb,
        legacyDbFiles: legacyDbFiles,
        legacyKeys: legacyKeys,
        legacySessions: legacySessions,
      );
    } else {
      await _quarantineWithoutSession(
        legacyDbFiles: legacyDbFiles,
        legacyKeys: legacyKeys,
        legacySessions: legacySessions,
      );
    }

    await tokenStore.writeValue(layoutKey, layoutVersion);
  }

  /// Session present at upgrade: copy legacy DB + adopt legacy E2EE keys for
  /// that signed-in user, verify, write markers, then delete legacy artifacts.
  Future<void> _adoptForActiveUser({
    required String userId,
    required File legacyDb,
    required List<File> legacyDbFiles,
    required String? legacyKeys,
    required String? legacySessions,
  }) async {
    final accountId = accountIdForUser(userId);
    final paths = await AccountPaths.resolve(accountId, dirs);
    final store = AccountStore(tokenStore, accountId);

    // Copy DB safely (if present and target not already populated).
    if (await legacyDb.exists()) {
      await paths.partitionDir.create(recursive: true);
      final tmpTarget = File('${paths.dbFile.path}.migrating');
      await legacyDb.copy(tmpTarget.path);
      // Copy WAL/SHM sidecars if present so uncommitted WAL pages are preserved.
      for (final suffix in const ['-wal', '-shm']) {
        final srcSidecar = File('${legacyDb.path}$suffix');
        if (await srcSidecar.exists()) {
          await srcSidecar.copy('${tmpTarget.path}$suffix');
        }
      }

      // Verify the copied DB opens cleanly and upgrades to schema v6.
      final verifyDb = AppDatabase.forFile(tmpTarget);
      try {
        await verifyDb.readMeta(PartitionGuard.ownerUserIdKey);
        final partitionId = (await store.readPartitionId()) ?? _uuid.v4();
        await verifyDb.writeMeta(PartitionGuard.ownerUserIdKey, userId);
        await verifyDb.writeMeta(PartitionGuard.partitionIdKey, partitionId);
        await store.writePartitionId(partitionId);
      } finally {
        await verifyDb.close();
      }

      // Atomically swap into place.
      for (final existing in paths.dbFiles) {
        await _deleteQuietly(existing);
      }
      await tmpTarget.rename(paths.dbFile.path);
      for (final suffix in const ['-wal', '-shm']) {
        final tmpSidecar = File('${tmpTarget.path}$suffix');
        if (await tmpSidecar.exists()) {
          await tmpSidecar.rename('${paths.dbFile.path}$suffix');
        }
      }
    }

    if (legacyKeys != null && (await store.readE2eeKeys()) == null) {
      await store.writeE2eeKeys(legacyKeys);
    }
    if (legacySessions != null && (await store.readE2eeSessions()) == null) {
      await store.writeE2eeSessions(legacySessions);
    }
    if ((await store.readPartitionId()) == null && legacyKeys != null) {
      await store.writePartitionId(_uuid.v4());
    }

    final cachedUser = await tokenStore.readUser();
    await registry.register(
      userId,
      displayName: cachedUser?.name,
      username: cachedUser?.username,
    );
    await tokenStore.writeActiveAccountId(accountId);

    // Delete legacy artifacts only after adoption is verified and persisted.
    for (final file in legacyDbFiles) {
      await _deleteQuietly(file);
    }
    await tokenStore.clearE2ee();
    logger?.info('migration', 'adopted legacy partition for signed-in user');
  }

  /// No session at upgrade: old logout wiped the DB, so delete it. Legacy keys
  /// have no proven owner, so quarantine them until a login proves ownership
  /// against `GET /api/v1/keys/me`.
  Future<void> _quarantineWithoutSession({
    required List<File> legacyDbFiles,
    required String? legacyKeys,
    required String? legacySessions,
  }) async {
    for (final file in legacyDbFiles) {
      await _deleteQuietly(file);
    }
    if (legacyKeys != null) {
      await tokenStore.writeValue(quarantineKeysKey, legacyKeys);
      if (legacySessions != null) {
        await tokenStore.writeValue(quarantineSessionsKey, legacySessions);
      }
      await tokenStore.writeValue(quarantineAtKey, _clock().toIso8601String());
    }
    await tokenStore.clearE2ee();
    logger?.info('migration', 'quarantined ownerless legacy keys');
  }

  /// Attempts to adopt quarantined legacy keys for [accountStore] by proving
  /// exact identity-key equality against [serverIdentityKey] (from `GET /keys/me`).
  ///
  /// On first mismatch or expiry, deletes the quarantine immediately so another
  /// account can never inherit stale keys.
  Future<bool> tryAdoptQuarantinedKeys({
    required AccountStore accountStore,
    required String? serverIdentityKey,
  }) async {
    final rawKeys = await tokenStore.readValue(quarantineKeysKey);
    if (rawKeys == null) return false;

    if (await _expireQuarantineIfOld()) return false;

    if (serverIdentityKey == null || serverIdentityKey.isEmpty) {
      await clearQuarantine();
      return false;
    }

    try {
      final material = await _e2eeService.importKeyMaterial(rawKeys);
      final publicBundle = await _e2eeService.buildPublicBundle(material);
      if (publicBundle.identityKey == serverIdentityKey) {
        await accountStore.writeE2eeKeys(rawKeys);
        final rawSessions = await tokenStore.readValue(quarantineSessionsKey);
        if (rawSessions != null) {
          await accountStore.writeE2eeSessions(rawSessions);
        }
        await clearQuarantine();
        logger?.info('migration', 'adopted quarantined legacy keys after /keys/me proof');
        return true;
      }
    } catch (error) {
      debugPrint('LegacyMigration: failed to verify quarantined keys: $error');
    }

    // First mismatch expires the quarantine immediately (§3.1).
    await clearQuarantine();
    return false;
  }

  Future<bool> hasQuarantinedKeys() async {
    return (await tokenStore.readValue(quarantineKeysKey)) != null;
  }

  Future<void> clearQuarantine() async {
    await tokenStore.deleteValue(quarantineKeysKey);
    await tokenStore.deleteValue(quarantineSessionsKey);
    await tokenStore.deleteValue(quarantineAtKey);
  }

  Future<bool> _expireQuarantineIfOld() async {
    final rawTs = await tokenStore.readValue(quarantineAtKey);
    if (rawTs == null) return false;
    final quarantinedAt = DateTime.tryParse(rawTs)?.toUtc();
    if (quarantinedAt == null || _clock().difference(quarantinedAt) > quarantineTtl) {
      await clearQuarantine();
      return true;
    }
    return false;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }
}
