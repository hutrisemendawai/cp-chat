import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

class LocalConversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get name => text().nullable()();

  /// Display name for a direct conversation: the other participant.
  TextColumn get peerName => text().nullable()();

  /// Group avatar object key, resolved through the media endpoint.
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get lastMessagePreview => text().nullable()();

  IntColumn get lastSeq => integer().withDefault(const Constant(0))();
  IntColumn get lastReadSeq => integer().withDefault(const Constant(0))();
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

@DriftDatabase(tables: [LocalConversations, LocalMessages, OutboxEntries])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'cp_chat'));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 4;

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
        },
        beforeOpen: (details) async {
          // The outbox is the source of truth for unsent work; foreign keys and
          // WAL keep reads fast while a send is in flight.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
