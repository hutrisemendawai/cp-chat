import 'dart:io';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_paths.dart';
import 'package:cp_chat/core/account/account_scope.dart';
import 'package:cp_chat/core/account/account_store.dart';
import 'package:cp_chat/core/account/partition_guard.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/factories.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDirs dirs;
  late _MapTokenStore tokenStore;
  late AccountPaths paths;
  late AccountStore accountStore;
  late DbGate gate;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cpchat_pguard_');
    dirs = AppDirs.forTesting(root);
    await dirs.initialize();
    tokenStore = _MapTokenStore();
    final acctId = accountIdForUser('user-a');
    paths = await AccountPaths.resolve(acctId, dirs);
    accountStore = AccountStore(tokenStore, acctId);
    gate = DbGate();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  PartitionGuard makeGuard() => PartitionGuard(
        store: accountStore,
        userId: 'user-a',
        paths: paths,
        gate: gate,
      );

  group('PartitionGuard (§2.9)', () {
    test('DB absent + keys absent -> fresh partition with paired markers', () async {
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);

      final result = await makeGuard().verify(db);
      expect(result.status, PartitionStatus.fresh);
      expect(result.isFreshStart, isTrue);
      expect(await db.readMeta(PartitionGuard.ownerUserIdKey), 'user-a');
      expect(await db.readMeta(PartitionGuard.partitionIdKey), result.partitionId);
      expect(await accountStore.readPartitionId(), result.partitionId);
    });

    test('DB present + keys present + markers equal -> intact', () async {
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);

      await db.writeMeta(PartitionGuard.ownerUserIdKey, 'user-a');
      await db.writeMeta(PartitionGuard.partitionIdKey, 'pid-1');
      await accountStore.writePartitionId('pid-1');
      await accountStore.writeE2eeKeys('{"k":1}');

      final result = await makeGuard().verify(db);
      expect(result.status, PartitionStatus.intact);
      expect(result.isFreshStart, isFalse);
      expect(await accountStore.readE2eeKeys(), '{"k":1}');
    });

    test('DB missing + keys present -> clears stale keys and starts fresh', () async {
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);

      // Keys survived in Keystore, but DB has no account_meta (DB was lost).
      await accountStore.writeE2eeKeys('{"stale":true}');
      await accountStore.writeE2eeSessions('{"peer":[]}');
      await accountStore.writePartitionId('old-pid');

      final result = await makeGuard().verify(db);
      expect(result.status, PartitionStatus.freshAfterDbLoss);
      expect(result.isFreshStart, isTrue);
      expect(await accountStore.readE2eeKeys(), isNull);
      expect(await accountStore.readE2eeSessions(), isNull);
      expect(await db.readMeta(PartitionGuard.partitionIdKey), result.partitionId);
      expect(await accountStore.readPartitionId(), result.partitionId);
    });

    test('DB present + keys missing (Keystore loss) -> preserves DB history', () async {
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);

      await db.writeMeta(PartitionGuard.ownerUserIdKey, 'user-a');
      await db.writeMeta(PartitionGuard.partitionIdKey, 'pid-1');
      await ChatDao(db).upsertServerMessage(
        message('m1', seq: 1, content: 'readable local history'),
      );
      // Keystore lost: no keys, no store partition_id.

      final result = await makeGuard().verify(db);
      expect(result.status, PartitionStatus.keysLostDbKept);
      expect(result.isFreshStart, isFalse);
      expect((await ChatDao(db).message('m1'))?.content, 'readable local history');
      expect(await accountStore.readPartitionId(), 'pid-1');
    });

    test('owner mismatch -> closes, deletes, and recreates clean DB', () async {
      final db = AppDatabase.forAccount(paths);
      await db.writeMeta(PartitionGuard.ownerUserIdKey, 'user-other');
      await db.writeMeta(PartitionGuard.partitionIdKey, 'pid-other');
      await ChatDao(db).upsertServerMessage(
        message('leak', seq: 1, content: 'someone else secret'),
      );
      await accountStore.writeE2eeKeys('{"other":true}');

      final result = await makeGuard().verify(db);
      addTearDown(result.database.close);

      expect(result.status, PartitionStatus.recreated);
      expect(result.isFreshStart, isTrue);
      expect(db.isClosed, isTrue);
      expect(await ChatDao(result.database).message('leak'), isNull);
      expect(await accountStore.readE2eeKeys(), isNull);
      expect(await result.database.readMeta(PartitionGuard.ownerUserIdKey), 'user-a');
    });

    test('partition marker mismatch -> recreates clean DB', () async {
      final db = AppDatabase.forAccount(paths);
      await db.writeMeta(PartitionGuard.ownerUserIdKey, 'user-a');
      await db.writeMeta(PartitionGuard.partitionIdKey, 'pid-db');
      await accountStore.writePartitionId('pid-store-different');
      await accountStore.writeE2eeKeys('{"k":1}');
      await ChatDao(db).upsertServerMessage(message('old', seq: 1, content: 'stale'));

      final result = await makeGuard().verify(db);
      addTearDown(result.database.close);

      expect(result.status, PartitionStatus.recreated);
      expect(await ChatDao(result.database).message('old'), isNull);
      expect(await accountStore.readE2eeKeys(), isNull);
    });
  });
}
