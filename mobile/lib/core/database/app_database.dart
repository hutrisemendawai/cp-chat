import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../account/account_paths.dart';
import '../account/account_scope.dart';
import '../storage/app_dirs.dart';

part 'app_database.g.dart';

class LocalConversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get name => text().nullable()();

  /// Display name for a direct conversation: the other participant.
  TextColumn get peerName => text().nullable()();

  /// The other participant's id, used to subscribe to their live presence.
  TextColumn get peerId => text().nullable()();

  /// The peer's nickname, rendered as `Name (nickname)` in the chat list.
  TextColumn get peerNickname => text().nullable()();

  /// Peer avatar object key for direct chats, resolved via the media endpoint.
  TextColumn get peerAvatarUrl => text().nullable()();

  /// Group avatar object key, resolved through the media endpoint.
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get lastMessagePreview => text().nullable()();

  IntColumn get lastSeq => integer().withDefault(const Constant(0))();
  IntColumn get lastReadSeq => integer().withDefault(const Constant(0))();

  /// Per-member history watermark (`conversation_members.cleared_seq`).
  /// Messages with `seq <= clearedSeq` are cleared for this account.
  IntColumn get clearedSeq => integer().withDefault(const Constant(0))();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class LocalMessages extends Table {
  TextColumn get clientMsgId => text()();
  TextColumn get id => text().nullable()();
  TextColumn get conversationId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get senderId => text()();
  TextColumn get type => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// Aggregated group read state for messages this user sent. `null` until a
  /// `read_receipt` frame arrives.
  IntColumn get readCount => integer().nullable()();
  IntColumn get memberCount => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {clientMsgId};

  /// Server `seq` is unique per conversation. Rows still in the outbox have a
  /// NULL `seq`, and SQLite treats NULLs as distinct, so they never collide.
  @override
  List<String> get customConstraints => [
        'UNIQUE (conversation_id, seq)',
      ];
}

class OutboxEntries extends Table {
  TextColumn get clientMsgId => text()();
  TextColumn get conversationId => text()();
  TextColumn get type => text()();

  /// Display content, stored locally as the user typed it.
  TextColumn get content => text()();

  /// Body actually written to the socket. For an encrypted direct chat this is
  /// the ciphertext envelope; a retry must resend the identical bytes because
  /// re-encrypting would advance the ratchet and the peer could not decrypt it.
  TextColumn get wireContent => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {clientMsgId};
}

/// Partition metadata stored inside each per-account database.
///
/// Tracks `owner_user_id` (asserted on open) and `partition_id` (paired with
/// secure storage `acct.<id>.partition_id` to detect split DB/Keystore state).
class AccountMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Unsent composer drafts per conversation, isolated inside the account DB.
class Drafts extends Table {
  TextColumn get conversationId => text()();
  TextColumn get body => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

@DriftDatabase(
  tables: [LocalConversations, LocalMessages, OutboxEntries, AccountMeta, Drafts],
)
class AppDatabase extends _$AppDatabase {
  /// Opens a file-backed database for a single account partition.
  AppDatabase.forFile(File file)
      : filePath = file.path,
        super(
          LazyDatabase(() async {
            await file.parent.create(recursive: true);
            return NativeDatabase(file);
          }),
        );

  /// Opens the database located at [paths.dbFile].
  AppDatabase.forAccount(AccountPaths paths) : this.forFile(paths.dbFile);

  /// Opens an account database lazily after resolving [AppDirs] and awaiting
  /// any pending close of the same file in [DbGate] (§3.2).
  AppDatabase.forAccountLazy({
    required String accountId,
    required AppDirs dirs,
    required DbGate gate,
  })  : filePath = dirs.cachedNoBackupDir == null
            ? null
            : AccountPaths(
                accountId: accountId,
                noBackupRoot: dirs.cachedNoBackupDir!,
                cacheRoot: dirs.cachedCacheDir ?? dirs.cachedNoBackupDir!,
              ).dbFile.path,
        super(
          LazyDatabase(() async {
            final paths = await AccountPaths.resolve(accountId, dirs);
            await gate.waitFor(paths.dbFile.path);
            await paths.partitionDir.create(recursive: true);
            return NativeDatabase(paths.dbFile);
          }),
        );

  AppDatabase.forTesting(super.executor, {this.filePath});

  /// Canonical file path for [DbGate] serialisation, or `null` for in-memory DBs.
  final String? filePath;

  bool _closed = false;
  bool get isClosed => _closed;

  @override
  int get schemaVersion => 6;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await super.close();
  }

  /// Reads a metadata key from `account_meta`.
  Future<String?> readMeta(String key) async {
    final row = await (select(accountMeta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  /// Upserts a metadata key in `account_meta`.
  Future<void> writeMeta(String key, String value) async {
    await into(accountMeta).insertOnConflictUpdate(
      AccountMetaCompanion.insert(key: key, value: value),
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.addColumn(localConversations, localConversations.peerName);
            await migrator.addColumn(
              localConversations,
              localConversations.lastMessagePreview,
            );
          }
          if (from < 3) {
            await migrator.addColumn(localConversations, localConversations.avatarUrl);
            await migrator.addColumn(localMessages, localMessages.readCount);
            await migrator.addColumn(localMessages, localMessages.memberCount);
          }
          if (from < 4) {
            // Existing outbox rows were plaintext; NULL wire content means
            // "send the stored content unchanged".
            await migrator.addColumn(outboxEntries, outboxEntries.wireContent);
          }
          if (from < 5) {
            // Direct-chat peer identity for the list: id for live presence,
            // nickname for the "Name (nickname)" label, avatar for the badge.
            await migrator.addColumn(localConversations, localConversations.peerId);
            await migrator.addColumn(localConversations, localConversations.peerNickname);
            await migrator.addColumn(localConversations, localConversations.peerAvatarUrl);
          }
          if (from < 6) {
            await migrator.addColumn(localConversations, localConversations.clearedSeq);
            await migrator.createTable(accountMeta);
            await migrator.createTable(drafts);
          }
        },
        beforeOpen: (details) async {
          // Enforce FK integrity, enable WAL for concurrent reads during writes,
          // and set busy_timeout so brief open/close handoffs never throw SQLITE_BUSY.
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA busy_timeout = 5000');
        },
      );
}
