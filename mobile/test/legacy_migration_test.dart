import 'dart:io';

import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_paths.dart';
import 'package:cp_chat/core/account/account_registry.dart';
import 'package:cp_chat/core/account/account_store.dart';
import 'package:cp_chat/core/account/legacy_migration.dart';
import 'package:cp_chat/core/account/partition_guard.dart';
import 'package:cp_chat/core/crypto/e2ee_service.dart';
import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/factories.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAllValues() async => Map.of(data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppDirs dirs;
  late _MapTokenStore tokenStore;
  late AccountRegistry registry;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cpchat_legacy_mig_');
    dirs = AppDirs.forTesting(root);
    await dirs.initialize();
    tokenStore = _MapTokenStore();
    now = DateTime.utc(2026, 11, 26, 12, 0);
    registry = AccountRegistry(tokenStore, clock: () => now);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<File> seedLegacyDb(String convId, String msgBody) async {
    final docs = await dirs.documentsDir();
    final legacyFile = File(p.join(docs.path, 'cp_chat.sqlite'));
    final db = AppDatabase.forFile(legacyFile);
    final dao = ChatDao(db);
    await dao.upsertConversation(conversation(convId, selfId: 'user-a'), selfId: 'user-a');
    await dao.upsertServerMessage(
      message('m1', conversationId: convId, seq: 1, content: msgBody),
    );
    await db.close();
    return legacyFile;
  }

  group('LegacyMigration (§3.1)', () {
    test('session present: adopts legacy DB and keys, writes markers, deletes legacy', () async {
      final e2ee = E2eeService(prekeyCount: 2);
      final material = await e2ee.generateKeyMaterial();
      final keyBlob = await e2ee.exportKeyMaterial(material);

      final legacyFile = await seedLegacyDb('conv-legacy', 'migrated hello');
      await tokenStore.saveSession(
        accessToken: 'acc',
        refreshToken: 'ref',
        userId: 'user-a',
      );
      await tokenStore.writeE2eeKeys(keyBlob);
      await tokenStore.writeE2eeSessions('{"peer-1":[]}');

      final migration = LegacyMigration(
        tokenStore: tokenStore,
        dirs: dirs,
        registry: registry,
        clock: () => now,
      );
      await migration.runIfNeeded();

      // Layout marker written; legacy files & global keys removed.
      expect(await tokenStore.readValue(LegacyMigration.layoutKey), LegacyMigration.layoutVersion);
      expect(await legacyFile.exists(), isFalse);
      expect(await tokenStore.readE2eeKeys(), isNull);
      expect(await tokenStore.readE2eeSessions(), isNull);

      // Account partition holds the migrated DB, keys, sessions, and markers.
      final acctId = accountIdForUser('user-a');
      final store = AccountStore(tokenStore, acctId);
      expect(await store.readE2eeKeys(), keyBlob);
      expect(await store.readE2eeSessions(), '{"peer-1":[]}');
      expect(await store.readPartitionId(), isNotNull);

      final paths = await AccountPaths.resolve(acctId, dirs);
      expect(await paths.dbFile.exists(), isTrue);
      final migratedDb = AppDatabase.forAccount(paths);
      addTearDown(migratedDb.close);
      expect(await migratedDb.readMeta(PartitionGuard.ownerUserIdKey), 'user-a');
      expect(await migratedDb.readMeta(PartitionGuard.partitionIdKey), await store.readPartitionId());
      final msg = await ChatDao(migratedDb).message('m1');
      expect(msg?.content, 'migrated hello');

      // Re-running is a no-op (idempotent).
      await migration.runIfNeeded();
      expect((await ChatDao(migratedDb).message('m1'))?.content, 'migrated hello');
    });

    test('no session: deletes legacy DB and quarantines keys; adopts only on /keys/me match', () async {
      final e2ee = E2eeService(prekeyCount: 2);
      final material = await e2ee.generateKeyMaterial();
      final keyBlob = await e2ee.exportKeyMaterial(material);
      final publicBundle = await e2ee.buildPublicBundle(material);

      final legacyFile = await seedLegacyDb('conv-old', 'should be deleted');
      await tokenStore.writeE2eeKeys(keyBlob);
      await tokenStore.writeE2eeSessions('{"peer-1":[]}');

      final migration = LegacyMigration(
        tokenStore: tokenStore,
        dirs: dirs,
        registry: registry,
        clock: () => now,
      );
      await migration.runIfNeeded();

      expect(await legacyFile.exists(), isFalse);
      expect(await tokenStore.readE2eeKeys(), isNull);
      expect(await migration.hasQuarantinedKeys(), isTrue);

      // Owner logs in and /keys/me matches the quarantined identity key -> adopted!
      final acctA = AccountStore(tokenStore, accountIdForUser('user-a'));
      final adopted = await migration.tryAdoptQuarantinedKeys(
        accountStore: acctA,
        serverIdentityKey: publicBundle.identityKey,
      );
      expect(adopted, isTrue);
      expect(await acctA.readE2eeKeys(), keyBlob);
      expect(await acctA.readE2eeSessions(), '{"peer-1":[]}');
      expect(await migration.hasQuarantinedKeys(), isFalse);
    });

    test('quarantined keys are deleted immediately on first mismatch (wrong user B)', () async {
      final e2ee = E2eeService(prekeyCount: 2);
      final materialA = await e2ee.generateKeyMaterial();
      final keyBlobA = await e2ee.exportKeyMaterial(materialA);

      await tokenStore.writeE2eeKeys(keyBlobA);

      final migration = LegacyMigration(
        tokenStore: tokenStore,
        dirs: dirs,
        registry: registry,
        clock: () => now,
      );
      await migration.runIfNeeded();
      expect(await migration.hasQuarantinedKeys(), isTrue);

      // User B logs in with a different server identity -> mismatch discards quarantine.
      final acctB = AccountStore(tokenStore, accountIdForUser('user-b'));
      final adopted = await migration.tryAdoptQuarantinedKeys(
        accountStore: acctB,
        serverIdentityKey: 'different-identity-key-from-bob',
      );
      expect(adopted, isFalse);
      expect(await acctB.readE2eeKeys(), isNull);
      expect(await migration.hasQuarantinedKeys(), isFalse);
    });

    test('quarantined keys expire after 30 days', () async {
      final e2ee = E2eeService(prekeyCount: 1);
      final material = await e2ee.generateKeyMaterial();
      final keyBlob = await e2ee.exportKeyMaterial(material);
      final publicBundle = await e2ee.buildPublicBundle(material);

      await tokenStore.writeE2eeKeys(keyBlob);

      final migration = LegacyMigration(
        tokenStore: tokenStore,
        dirs: dirs,
        registry: registry,
        clock: () => now,
      );
      await migration.runIfNeeded();
      expect(await migration.hasQuarantinedKeys(), isTrue);

      // Advance 31 days -> expired even if identity key would have matched.
      now = now.add(const Duration(days: 31));
      final acctA = AccountStore(tokenStore, accountIdForUser('user-a'));
      final adopted = await migration.tryAdoptQuarantinedKeys(
        accountStore: acctA,
        serverIdentityKey: publicBundle.identityKey,
      );
      expect(adopted, isFalse);
      expect(await acctA.readE2eeKeys(), isNull);
      expect(await migration.hasQuarantinedKeys(), isFalse);
    });

    test('crash mid-migration leaves legacy intact and re-run completes cleanly', () async {
      final legacyFile = await seedLegacyDb('conv-crash', 'survives crash');
      await tokenStore.saveSession(
        accessToken: 'acc',
        refreshToken: 'ref',
        userId: 'user-a',
      );
      // Simulate leftover partial `.migrating` artifact from a crashed run
      // before `local_layout` was written.
      final paths = await AccountPaths.resolve(accountIdForUser('user-a'), dirs);
      await paths.partitionDir.create(recursive: true);
      final leftover = File('${paths.dbFile.path}.migrating');
      await leftover.writeAsString('corrupt partial');

      final migration = LegacyMigration(
        tokenStore: tokenStore,
        dirs: dirs,
        registry: registry,
        clock: () => now,
      );
      await migration.runIfNeeded();

      expect(await legacyFile.exists(), isFalse);
      expect(await paths.dbFile.exists(), isTrue);
      final db = AppDatabase.forAccount(paths);
      addTearDown(db.close);
      expect((await ChatDao(db).message('m1'))?.content, 'survives crash');
    });
  });
}
