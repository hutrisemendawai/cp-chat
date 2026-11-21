import 'package:drift/drift.dart';

import '../models/models.dart';
import 'app_database.dart';

/// Local mirror of server state plus the outbox for unsent messages.
///
/// Every write is idempotent: the server is authoritative, and the same row can
/// arrive from a live `message` event, a REST sync, or the optimistic local
/// insert, in any order.
class ChatDao {
  ChatDao(this.db);

  final AppDatabase db;

  Stream<List<LocalConversation>> watchConversations() {
    return (db.select(db.localConversations)
          ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)]))
        .watch();
  }

  Future<List<LocalConversation>> conversations() =>
      (db.select(db.localConversations)
            ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)]))
          .get();

  Stream<LocalConversation?> watchConversation(String id) {
    return (db.select(db.localConversations)..where((table) => table.id.equals(id)))
        .watchSingleOrNull();
  }

  Future<LocalConversation?> conversation(String id) {
    return (db.select(db.localConversations)..where((table) => table.id.equals(id)))
        .getSingleOrNull();
  }

  Stream<List<LocalMessage>> watchMessages(String conversationId) {
    return (db.select(db.localMessages)
          ..where((table) => table.conversationId.equals(conversationId))
          ..orderBy([
            // Unsynced rows have no server seq yet; sort them by creation time
            // after the ordered history so optimistic bubbles stay at the end.
            (table) => OrderingTerm.asc(table.seq),
            (table) => OrderingTerm.asc(table.createdAt),
          ]))
        .watch();
  }

  Future<int> localMaxSeq(String conversationId) async {
    final row = await (db.selectOnly(db.localMessages)
          ..addColumns([db.localMessages.seq.max()])
          ..where(db.localMessages.conversationId.equals(conversationId)))
        .getSingle();
    return row.read(db.localMessages.seq.max()) ?? 0;
  }

  /// Highest `seq` received from anyone other than `selfId`. The read cursor is
  /// built from this so reading your own messages never generates an ack.
  Future<int> latestSeqFromOthers(String conversationId, String selfId) async {
    final row = await (db.selectOnly(db.localMessages)
          ..addColumns([db.localMessages.seq.max()])
          ..where(
            db.localMessages.conversationId.equals(conversationId) &
                db.localMessages.senderId.equals(selfId).not(),
          ))
        .getSingle();
    return row.read(db.localMessages.seq.max()) ?? 0;
  }

  /// Replaces the conversation list from a fresh server response. Direct
  /// conversations have no server-side name, so the peer's name is cached for
  /// display and cheap sorting without refetching members.
  Future<void> upsertConversations(List<Conversation> conversations, {String? selfId}) async {
    await db.batch((batch) {
      for (final conversation in conversations) {
        batch.insert(
          db.localConversations,
          LocalConversationsCompanion.insert(
            id: conversation.id,
            type: conversation.type,
            name: Value(conversation.name),
            peerName: Value(_peerName(conversation, selfId)),
            avatarUrl: Value(conversation.avatarUrl),
            lastMessagePreview: Value(_preview(conversation.lastMessage)),
            lastSeq: Value(conversation.lastSeq),
            lastReadSeq: Value(conversation.lastReadSeq),
            unreadCount: Value(conversation.unreadCount),
            updatedAt: conversation.lastMessage?.createdAt ?? conversation.createdAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> upsertConversation(
    Conversation conversation, {
    bool preserveLocalCursor = true,
    String? selfId,
  }) async {
    final existing = await this.conversation(conversation.id);
    final lastSeq = preserveLocalCursor && existing != null
        ? (existing.lastSeq > conversation.lastSeq ? existing.lastSeq : conversation.lastSeq)
        : conversation.lastSeq;
    final updatedAt = conversation.lastMessage?.createdAt ?? conversation.createdAt;

    await db.into(db.localConversations).insertOnConflictUpdate(
          LocalConversationsCompanion.insert(
            id: conversation.id,
            type: conversation.type,
            name: Value(conversation.name),
            peerName: Value(_peerName(conversation, selfId) ?? existing?.peerName),
            avatarUrl: Value(conversation.avatarUrl),
            lastMessagePreview: Value(_preview(conversation.lastMessage)),
            lastSeq: Value(lastSeq),
            lastReadSeq: Value(conversation.lastReadSeq),
            unreadCount: Value(conversation.unreadCount),
            updatedAt: updatedAt,
          ),
        );
  }

  String? _peerName(Conversation conversation, String? selfId) {
    if (selfId == null) return null;
    // Groups display their own name; caching a member as the "peer" would
    // shadow it in the chat header.
    if (conversation.type == 'group') return null;
    return conversation.otherMember(selfId)?.user.name;
  }

  String? _preview(Message? message) {
    if (message == null) return null;
    if (message.type != 'text') return 'Sent an attachment';
    return message.content;
  }

  /// Applies an optimistic local send: the message row and the outbox entry are
  /// committed together so a crash cannot lose an unsent message.
  ///
  /// [content] is what the UI renders; [wireContent] is what goes on the socket
  /// when it differs (an E2EE ciphertext envelope). A retry reuses
  /// [wireContent] verbatim so the ratchet is not advanced a second time.
  Future<void> enqueueOutgoing({
    required String clientMsgId,
    required String conversationId,
    required String senderId,
    required String type,
    required String content,
    String? wireContent,
    required DateTime createdAt,
  }) async {
    await db.transaction(() async {
      await db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              clientMsgId: clientMsgId,
              conversationId: conversationId,
              senderId: senderId,
              type: type,
              content: content,
              createdAt: createdAt,
              status: const Value('pending'),
            ),
          );
      await db.into(db.outboxEntries).insertOnConflictUpdate(
            OutboxEntriesCompanion.insert(
              clientMsgId: clientMsgId,
              conversationId: conversationId,
              type: type,
              content: content,
              wireContent: Value(wireContent),
              createdAt: createdAt,
            ),
          );
    });
  }

  /// Stores a server message, reconciling the optimistic row by client id.
  Future<void> upsertServerMessage(Message message, {String status = 'sent'}) async {
    final existing = await (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
        .getSingleOrNull();

    await db.into(db.localMessages).insertOnConflictUpdate(
          LocalMessagesCompanion.insert(
            clientMsgId: message.clientMsgId,
            id: Value(message.id),
            conversationId: message.conversationId,
            seq: Value(message.seq),
            senderId: message.senderId,
            type: message.type,
            content: message.content,
            createdAt: message.createdAt,
            status: Value(_maxStatus(existing?.status, status)),
          ),
        );

    await (db.delete(db.outboxEntries)
          ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
        .go();

    await _bumpConversationCursor(message);
  }

  Future<void> upsertServerMessages(List<Message> messages) async {
    for (final message in messages) {
      await upsertServerMessage(message);
    }
  }

  /// A `status` frame advances lifecycle state; it never moves backwards.
  Future<void> applyStatus(String clientMsgId, String status) async {
    final existing = await (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .getSingleOrNull();
    if (existing == null) return;

    await (db.update(db.localMessages)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .write(LocalMessagesCompanion(status: Value(_maxStatus(existing.status, status))));
  }

  /// Stores the aggregated group read tally. Reading up to `upToSeq` means every
  /// message this user sent with `seq <= upToSeq` was seen by that many members.
  /// The count only grows, so replayed or out-of-order frames cannot lower it.
  Future<void> applyReadReceipt({
    required String conversationId,
    required String selfId,
    required int upToSeq,
    required int readCount,
    required int memberCount,
  }) async {
    final rows = await (db.select(db.localMessages)
          ..where(
            (table) =>
                table.conversationId.equals(conversationId) &
                table.senderId.equals(selfId) &
                table.seq.isNotNull() &
                table.seq.isSmallerOrEqualValue(upToSeq),
          ))
        .get();
    if (rows.isEmpty) return;

    await db.batch((batch) {
      for (final row in rows) {
        final current = row.readCount ?? 0;
        if (current >= readCount && row.memberCount == memberCount) continue;
        batch.update(
          db.localMessages,
          LocalMessagesCompanion(
            readCount: Value(current > readCount ? current : readCount),
            memberCount: Value(memberCount),
          ),
          where: (table) => table.clientMsgId.equals(row.clientMsgId),
        );
      }
    });
  }

  /// The conversation type, or `null` if it is not cached yet.
  Future<String?> conversationType(String conversationId) async {
    final row = await conversation(conversationId);
    return row?.type;
  }

  Future<void> markFailed(String clientMsgId) async {
    await (db.update(db.localMessages)..where((table) => table.clientMsgId.equals(clientMsgId)))
        .write(const LocalMessagesCompanion(status: Value('failed')));
  }

  Future<void> deleteMessage(String clientMsgId) async {
    await db.transaction(() async {
      await (db.delete(db.localMessages)..where((table) => table.clientMsgId.equals(clientMsgId)))
          .go();
      await (db.delete(db.outboxEntries)..where((table) => table.clientMsgId.equals(clientMsgId)))
          .go();
    });
  }

  Future<List<OutboxEntry>> pendingOutbox() async {
    final rows = await db.select(db.outboxEntries).get();
    rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return rows;
  }

  Future<void> recordAttempt(String clientMsgId) async {
    await (db.update(db.outboxEntries)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .write(
      OutboxEntriesCompanion(
        attempts: Value(
          await _attemptCount(clientMsgId),
        ),
        lastAttemptAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  Future<int> _attemptCount(String clientMsgId) async {
    final row = await (db.select(db.outboxEntries)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .getSingleOrNull();
    return (row?.attempts ?? 0) + 1;
  }

  Future<void> setReadCursor(String conversationId, int seq) async {
    final existing = await conversation(conversationId);
    if (existing == null) return;
    if (seq <= existing.lastReadSeq) return;

    await (db.update(db.localConversations)..where((table) => table.id.equals(conversationId)))
        .write(LocalConversationsCompanion(lastReadSeq: Value(seq)));
  }

  Future<void> clearUnread(String conversationId) async {
    await (db.update(db.localConversations)..where((table) => table.id.equals(conversationId)))
        .write(const LocalConversationsCompanion(unreadCount: Value(0)));
  }

  /// Drops a conversation and its messages locally, e.g. after leaving a group.
  Future<void> deleteConversation(String conversationId) async {
    await db.transaction(() async {
      await (db.delete(db.outboxEntries)
            ..where((table) => table.conversationId.equals(conversationId)))
          .go();
      await (db.delete(db.localMessages)
            ..where((table) => table.conversationId.equals(conversationId)))
          .go();
      await (db.delete(db.localConversations)..where((table) => table.id.equals(conversationId)))
          .go();
    });
  }

  Future<void> clearAll() async {
    await db.transaction(() async {
      await db.delete(db.outboxEntries).go();
      await db.delete(db.localMessages).go();
      await db.delete(db.localConversations).go();
    });
  }

  Future<void> _bumpConversationCursor(Message message) async {
    final existing = await conversation(message.conversationId);
    final newest = existing == null || message.createdAt.isAfter(existing.updatedAt)
        ? message.createdAt
        : existing.updatedAt;
    final lastSeq = existing == null || message.seq > existing.lastSeq
        ? message.seq
        : existing.lastSeq;

    await (db.update(db.localConversations)
          ..where((table) => table.id.equals(message.conversationId)))
        .write(
      LocalConversationsCompanion(
        lastSeq: Value(lastSeq),
        updatedAt: Value(newest),
        lastMessagePreview: Value(
          message.type == 'text' ? message.content : 'Sent an attachment',
        ),
      ),
    );
  }
}

const _statusOrder = {'pending': 0, 'sent': 1, 'delivered': 2, 'read': 3, 'failed': 4};

/// Keeps the furthest-along lifecycle state; `failed` is terminal and only
/// clears when the server confirms the message.
String _maxStatus(String? current, String incoming) {
  final a = _statusOrder[current] ?? 0;
  final b = _statusOrder[incoming] ?? 0;
  if (current == 'failed' && incoming != 'failed') return 'failed';
  return b > a ? incoming : (current ?? incoming);
}
