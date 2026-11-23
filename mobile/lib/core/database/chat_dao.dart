import 'package:drift/drift.dart';

import '../crypto/e2ee_service.dart' show isEncryptedContent, undecryptableContent;
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

  /// The local row for a message, or `null` when it has not been stored yet.
  Future<LocalMessage?> message(String clientMsgId) {
    return (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .getSingleOrNull();
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
            peerId: Value(_peerId(conversation, selfId)),
            peerNickname: Value(_peerNickname(conversation, selfId)),
            peerAvatarUrl: Value(_peerAvatar(conversation, selfId)),
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
            peerId: Value(_peerId(conversation, selfId) ?? existing?.peerId),
            peerNickname:
                Value(_peerNickname(conversation, selfId) ?? existing?.peerNickname),
            peerAvatarUrl:
                Value(_peerAvatar(conversation, selfId) ?? existing?.peerAvatarUrl),
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

  String? _peerId(Conversation conversation, String? selfId) {
    if (selfId == null || conversation.type == 'group') return null;
    return conversation.otherMember(selfId)?.user.id;
  }

  String? _peerNickname(Conversation conversation, String? selfId) {
    if (selfId == null || conversation.type == 'group') return null;
    return conversation.otherMember(selfId)?.user.nickname;
  }

  String? _peerAvatar(Conversation conversation, String? selfId) {
    if (selfId == null || conversation.type == 'group') return null;
    return conversation.otherMember(selfId)?.user.avatarUrl;
  }

  String? _preview(Message? message) {
    if (message == null) return null;
    if (message.type != 'text') return 'Sent an attachment';
    return _textPreview(message.content);
  }

  /// A body that is still a raw envelope (history restored before its session,
  /// or an own message synced back) must not leak ciphertext into the UI.
  String _textPreview(String content) =>
      isEncryptedContent(content) ? 'Encrypted message' : content;

  /// Keeps already-decrypted text when the incoming body is unreadable, so a
  /// sync or history page cannot regress a bubble to ciphertext.
  String _storedContent(String incoming, String? existing) {
    if (existing == null) return incoming;
    if (_isUnreadable(existing)) return incoming;
    return _isUnreadable(incoming) ? existing : incoming;
  }

  bool _isUnreadable(String content) =>
      isEncryptedContent(content) || content == undecryptableContent;

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
  ///
  /// Readable content is never replaced by an unreadable body. That happens for
  /// an own message synced back from the server (its receiving chain lives on
  /// the peer and cannot be replayed here), or for history re-fetched after the
  /// ratchet moved past it.
  Future<void> upsertServerMessage(Message message, {String status = 'sent'}) async {
    final existing = await (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
        .getSingleOrNull();

    final content = _storedContent(message.content, existing?.content);

    await db.into(db.localMessages).insertOnConflictUpdate(
          LocalMessagesCompanion.insert(
            clientMsgId: message.clientMsgId,
            id: Value(message.id),
            conversationId: message.conversationId,
            seq: Value(message.seq),
            senderId: message.senderId,
            type: message.type,
            content: content,
            createdAt: message.createdAt,
            status: Value(_maxStatus(existing?.status, status)),
          ),
        );

    await (db.delete(db.outboxEntries)
          ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
        .go();

    await _bumpConversationCursor(message, content);
  }

  Future<void> upsertServerMessages(List<Message> messages) async {
    for (final message in messages) {
      await upsertServerMessage(message);
    }
  }

  /// A `status` frame advances lifecycle state. Server-confirmed states
  /// (`sent`, `delivered`, `read`) also mean the message was accepted, so the
  /// row leaves the outbox and — when the frame carries it — records the
  /// server-assigned `seq`. This resolves a message that is still `pending` (or
  /// was marked `failed` by a timeout) without waiting for a sync.
  Future<void> applyStatus(String clientMsgId, String status, {int? seq}) async {
    final existing = await (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .getSingleOrNull();
    if (existing == null) return;

    final nextSeq = seq ?? existing.seq;
    final confirmed = _confirmedStatuses.contains(status);

    await db.transaction(() async {
      await (db.update(db.localMessages)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .write(
        LocalMessagesCompanion(
          status: Value(_maxStatus(existing.status, status)),
          seq: Value(nextSeq),
        ),
      );
      if (confirmed) {
        await (db.delete(db.outboxEntries)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .go();
      }
    });
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

  /// Returns a message to `pending` for a manual retry. Unlike [applyStatus],
  /// this deliberately clears a local `failed` so the bubble shows that a new
  /// attempt is in flight.
  Future<void> markPending(String clientMsgId) async {
    await (db.update(db.localMessages)..where((table) => table.clientMsgId.equals(clientMsgId)))
        .write(const LocalMessagesCompanion(status: Value('pending')));
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

  Future<void> _bumpConversationCursor(Message message, String content) async {
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
          message.type == 'text' ? _textPreview(content) : 'Sent an attachment',
        ),
      ),
    );
  }
}

/// States assigned by the server, which prove it accepted the message.
const _confirmedStatuses = {'sent', 'delivered', 'read'};

const _statusOrder = {'pending': 0, 'sent': 1, 'delivered': 2, 'read': 3, 'failed': 4};

/// Picks the furthest-along lifecycle state.
///
/// Server-confirmed states always win: a `failed` row is only a local "no ack
/// yet" marker, and a late-but-valid `sent`/`delivered`/`read` proves the send
/// succeeded, so the bubble must recover instead of staying red. Between two
/// confirmed states the furthest along wins (`sent` < `delivered` < `read`). A
/// local `failed` is kept over a still-`pending` retry so it does not flicker
/// back to "sending"; a manual retry clears it via [ChatDao.markPending].
String _maxStatus(String? current, String incoming) {
  final cur = current ?? incoming;
  final curConfirmed = _confirmedStatuses.contains(cur);
  final nextConfirmed = _confirmedStatuses.contains(incoming);

  if (nextConfirmed) {
    if (!curConfirmed) return incoming;
    return (_statusOrder[incoming] ?? 0) > (_statusOrder[cur] ?? 0) ? incoming : cur;
  }

  if (cur == 'failed' && incoming == 'pending') return cur;
  if (curConfirmed) return cur;
  return (_statusOrder[incoming] ?? 0) > (_statusOrder[cur] ?? 0) ? incoming : cur;
}
