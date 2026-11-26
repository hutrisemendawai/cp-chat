import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../logging/app_logger.dart';
import 'account_paths.dart';
import 'account_scope.dart';
import 'account_store.dart';

/// Outcome of verifying a local account partition on open (§2.9).
enum PartitionStatus {
  /// DB, keys, and integrity markers are present and match.
  intact,

  /// First login on this device or after a full clear (DB and keys absent).
  fresh,

  /// DB was missing/empty while keys existed (e.g. partial delete): keys were
  /// cleared so bootstrap rotates identity and avoids undecryptable stubs.
  freshAfterDbLoss,

  /// DB exists with matching owner while keys were missing (Keystore loss):
  /// DB is preserved and bootstrap will regenerate keys.
  keysLostDbKept,

  /// Owner or partition marker mismatch: partition was wiped and recreated.
  recreated,
}

/// Result of [PartitionGuard.verify].
class PartitionCheckResult {
  const PartitionCheckResult({
    required this.status,
    required this.database,
    required this.partitionId,
  });

  final PartitionStatus status;
  final AppDatabase database;
  final String partitionId;

  bool get isFreshStart =>
      status == PartitionStatus.fresh ||
      status == PartitionStatus.freshAfterDbLoss ||
      status == PartitionStatus.recreated;
}

/// Enforces local partition integrity on every account open (§2.9):
///
/// | State                                  | Action                                  |
/// |----------------------------------------|-----------------------------------------|
/// | DB ✓ keys ✓ markers equal              | normal ([PartitionStatus.intact])       |
/// | DB ✗ keys ✓                            | delete keys, fresh ([freshAfterDbLoss]) |
/// | DB ✓ keys ✗                            | keep DB, new marker ([keysLostDbKept])  |
/// | markers differ / owner ≠ scope user    | close, delete, recreate ([recreated])   |
/// | DB ✗ keys ✗                            | init markers ([fresh])                  |
class PartitionGuard {
  PartitionGuard({
    required this.store,
    required this.userId,
    this.paths,
    this.gate,
    this.openDatabase,
    this.logger,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  static const ownerUserIdKey = 'owner_user_id';
  static const partitionIdKey = 'partition_id';

  final AccountStore store;
  final String userId;
  final AccountPaths? paths;
  final DbGate? gate;
  final AppDatabase Function()? openDatabase;
  final AppLogger? logger;
  final Uuid _uuid;

  Future<PartitionCheckResult> verify(AppDatabase db) async {
    final dbOwner = await db.readMeta(ownerUserIdKey);
    final dbPartitionId = await db.readMeta(partitionIdKey);
    final storePartitionId = await store.readPartitionId();
    final hasKeys = (await store.readE2eeKeys()) != null;

    final hasDbState = dbOwner != null || dbPartitionId != null;

    // Case 1: Owner assertion failed — never allow cross-account DB reuse.
    if (dbOwner != null && dbOwner != userId) {
      logger?.warn(
        'account',
        'partition owner mismatch; recreating database',
        meta: {'expected_user': userId},
      );
      debugPrint('PartitionGuard: owner mismatch (expected $userId), recreating DB');
      return _recreate(db);
    }

    // Case 2: Both markers exist and disagree — split/restored state.
    if (dbPartitionId != null &&
        storePartitionId != null &&
        dbPartitionId != storePartitionId) {
      logger?.warn('account', 'partition marker mismatch; recreating database');
      debugPrint('PartitionGuard: partition_id mismatch, recreating DB');
      return _recreate(db);
    }

    // Case 3: DB is present & valid, keys are present, markers match.
    if (hasDbState && hasKeys && dbPartitionId != null && dbPartitionId == storePartitionId) {
      return PartitionCheckResult(
        status: PartitionStatus.intact,
        database: db,
        partitionId: dbPartitionId,
      );
    }

    // Case 4: DB missing/uninitialized, keys present => ratchets are useless
    // against re-served server ciphertext; discard keys and start fresh so
    // bootstrap rotates identity and triggers server direct watermark.
    if (!hasDbState && hasKeys) {
      logger?.warn('account', 'DB missing while keys present; clearing stale keys');
      await store.deleteE2ee();
      final newId = _uuid.v4();
      await db.writeMeta(ownerUserIdKey, userId);
      await db.writeMeta(partitionIdKey, newId);
      await store.writePartitionId(newId);
      return PartitionCheckResult(
        status: PartitionStatus.freshAfterDbLoss,
        database: db,
        partitionId: newId,
      );
    }

    // Case 5: DB present (with matching owner), keys missing (Keystore loss) =>
    // keep readable local DB history and re-pair partition marker; bootstrap
    // will generate fresh keys.
    if (hasDbState && !hasKeys) {
      logger?.warn('account', 'Keystore keys missing while DB intact; keeping DB');
      final nextId = dbPartitionId ?? _uuid.v4();
      await db.writeMeta(ownerUserIdKey, userId);
      await db.writeMeta(partitionIdKey, nextId);
      await store.writePartitionId(nextId);
      return PartitionCheckResult(
        status: PartitionStatus.keysLostDbKept,
        database: db,
        partitionId: nextId,
      );
    }

    // Case 6: Brand new / fresh partition (DB uninitialized, keys absent).
    final freshId = _uuid.v4();
    await db.writeMeta(ownerUserIdKey, userId);
    await db.writeMeta(partitionIdKey, freshId);
    await store.writePartitionId(freshId);
    return PartitionCheckResult(
      status: PartitionStatus.fresh,
      database: db,
      partitionId: freshId,
    );
  }

  Future<PartitionCheckResult> _recreate(AppDatabase oldDb) async {
    await store.deleteAll();
    final filePath = oldDb.filePath ?? paths?.dbFile.path;

    Future<AppDatabase> replace() async {
      await oldDb.close();
      if (paths != null) {
        for (final file in paths!.dbFiles) {
          await _deleteQuietly(file);
        }
      } else if (filePath != null) {
        for (final suffix in const ['', '-wal', '-shm', '-journal']) {
          await _deleteQuietly(File('$filePath$suffix'));
        }
      }
      if (openDatabase != null) return openDatabase!();
      if (paths != null) return AppDatabase.forAccount(paths!);
      if (filePath != null) return AppDatabase.forFile(File(filePath));
      throw StateError('Cannot recreate an in-memory database without openDatabase callback');
    }

    final AppDatabase replacement;
    if (gate != null && filePath != null) {
      replacement = await gate!.run(filePath, replace);
    } else {
      replacement = await replace();
    }

    final freshId = _uuid.v4();
    await replacement.writeMeta(ownerUserIdKey, userId);
    await replacement.writeMeta(partitionIdKey, freshId);
    await store.writePartitionId(freshId);

    return PartitionCheckResult(
      status: PartitionStatus.recreated,
      database: replacement,
      partitionId: freshId,
    );
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }
}
