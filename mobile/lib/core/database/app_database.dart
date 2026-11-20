import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

class LocalConversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get name => text().nullable()();
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

  @override
  Set<Column<Object>> get primaryKey => {clientMsgId};

  @override
  List<String> get customConstraints => [
        'UNIQUE (conversation_id, seq)',
      ];
}

class OutboxEntries extends Table {
  TextColumn get clientMsgId => text()();
  TextColumn get conversationId => text()();
  TextColumn get type => text()();
  TextColumn get content => text()();
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
  int get schemaVersion => 1;
}
