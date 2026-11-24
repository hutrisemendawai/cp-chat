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
    await db.transaction(() async {
      for (final item in conversations) {
        await _upsertConversation(item, selfId: selfId);
      }
    });
  }

  Future<void> upsertConversation(
    Conversation conversation, {
    bool preserveLocalCursor = true,
    String? selfId,
  }) async {
    await db.transaction(() => _upsertConversation(
          conversation,
          preserveLocalCursor: preserveLocalCursor,
          selfId: selfId,
        ));
  }

  Future<void> _upsertConversation(
    Conversation item, {
    bool preserveLocalCursor = true,
    String? selfId,
  }) async {
    final existing = await conversation(item.id);
    final pending = await _latestPending(item.id);
    final summary = item.lastMessage;
    final summarySeq = summary?.seq ?? item.lastSeq;
    final stale = existing != null && preserveLocalCursor &&
        (item.lastSeq < existing.lastSeq ||
            (summary != null && summarySeq < existing.lastSeq));
    String? preview;
    if (pending != null) {
      preview = _contentPreview(pending.type, pending.content);
    } else if (stale) {
      preview = _safePreview(existing.lastMessagePreview);
    } else if (summary == null) {
      preview = null;
    } else {
      preview = await _summaryPreview(item.id, summary);
      if (preview == 'Encrypted message' && existing != null &&
          item.lastSeq == existing.lastSeq && summary.seq == item.lastSeq &&
          existing.lastMessagePreview != null &&
          !await _hasConflictingMessage(item.id, summary)) {
        preview = _safePreview(existing.lastMessagePreview);
      }
    }
    final serverTime = summary?.createdAt ?? item.createdAt;
    var updatedAt = serverTime;
    if (existing != null && preserveLocalCursor && (stale || pending != null) &&
        existing.updatedAt.isAfter(updatedAt)) {
      updatedAt = existing.updatedAt;
    }
    if (pending != null && pending.createdAt.isAfter(updatedAt)) {
      updatedAt = pending.createdAt;
    }
    final lastSeq = preserveLocalCursor && existing != null && existing.lastSeq > item.lastSeq
        ? existing.lastSeq
        : item.lastSeq;
    await db.into(db.localConversations).insertOnConflictUpdate(
          LocalConversationsCompanion.insert(
            id: item.id,
            type: item.type,
            name: Value(item.name),
            peerName: Value(_peerName(item, selfId) ?? existing?.peerName),
            peerId: Value(_peerId(item, selfId) ?? existing?.peerId),
            peerNickname: Value(_peerNickname(item, selfId) ?? existing?.peerNickname),
            peerAvatarUrl: Value(_peerAvatar(item, selfId) ?? existing?.peerAvatarUrl),
            avatarUrl: Value(item.avatarUrl),
            lastMessagePreview: Value(preview),
            lastSeq: Value(lastSeq),
            lastReadSeq: Value(item.lastReadSeq),
            unreadCount: Value(item.unreadCount),
            updatedAt: updatedAt,
          ),
        );
  }

  Future<LocalMessage?> _latestPending(String conversationId) async {
    final rows = await db.customSelect(
      'SELECT pending.* FROM local_messages AS pending '
      'WHERE pending.conversation_id = ? AND pending.seq IS NULL '
      'AND NOT EXISTS (SELECT 1 FROM local_messages AS confirmed '
      'WHERE confirmed.conversation_id = pending.conversation_id '
      'AND confirmed.sender_id = pending.sender_id AND confirmed.seq IS NOT NULL '
      'AND (confirmed.created_at > pending.created_at OR '
      '(confirmed.created_at = pending.created_at AND confirmed.rowid > pending.rowid))) '
      'ORDER BY pending.created_at DESC, pending.rowid DESC LIMIT 1',
      variables: [Variable.withString(conversationId)],
      readsFrom: {db.localMessages},
    ).get();
    return rows.isEmpty ? null : db.localMessages.map(rows.single.data);
  }

  Future<String> _summaryPreview(String conversationId, Message summary) async {
    if (summary.type != 'text' || !_isUnreadable(summary.content)) {
      return _contentPreview(summary.type, summary.content);
    }
    final byId = await message(summary.clientMsgId);
    if (byId != null && byId.conversationId == conversationId &&
        (byId.seq == null || byId.seq == summary.seq) &&
        byId.type == 'text' && !_isUnreadable(byId.content)) {
      return byId.content;
    }
    final bySeq = await (db.select(db.localMessages)
          ..where((table) => table.conversationId.equals(conversationId) &
              table.seq.equals(summary.seq)))
        .getSingleOrNull();
    if (bySeq != null && bySeq.type == 'text' && !_isUnreadable(bySeq.content)) {
      return bySeq.content;
    }
    return 'Encrypted message';
  }

  Future<bool> _hasConflictingMessage(String conversationId, Message summary) async {
    final row = await (db.select(db.localMessages)
          ..where((table) => table.conversationId.equals(conversationId) &
              table.seq.equals(summary.seq)))
        .getSingleOrNull();
    return row != null && row.clientMsgId != summary.clientMsgId;
  }

  String? _safePreview(String? preview) =>
      preview == null ? null : _textPreview(preview);

  String _contentPreview(String type, String content) =>
      type == 'text' ? _textPreview(content) : 'Sent an attachment';

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

  String _textPreview(String content) =>
      _isUnreadable(content) ? 'Encrypted message' : content;

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
      await _refreshPendingPreview(conversationId);
    });
  }

  Future<void> _refreshPendingPreview(String conversationId) async {
    final existing = await conversation(conversationId);
    final pending = await _latestPending(conversationId);
    if (existing == null || pending == null) return;
    await (db.update(db.localConversations)..where((table) => table.id.equals(conversationId)))
        .write(LocalConversationsCompanion(
      lastMessagePreview: Value(_contentPreview(pending.type, pending.content)),
      updatedAt: Value(pending.createdAt.isAfter(existing.updatedAt)
          ? pending.createdAt
          : existing.updatedAt),
    ));
  }

  /// Stores a server message, reconciling the optimistic row by client id.
  ///
  /// Readable content is never replaced by an unreadable body. That happens for
  /// an own message synced back from the server (its receiving chain lives on
  /// the peer and cannot be replayed here), or for history re-fetched after the
  /// ratchet moved past it.
  Future<void> upsertServerMessage(Message message, {String status = 'sent'}) async {
    await db.transaction(() async {
      final existing = await this.message(message.clientMsgId);
      if (existing != null && existing.conversationId != message.conversationId) {
        throw StateError('Message id belongs to another conversation');
      }
      final pendingBefore = await _latestPending(message.conversationId);
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
              createdAt: existing != null && existing.seq == null
                  ? existing.createdAt
                  : message.createdAt,
              status: Value(_maxStatus(existing?.status, status)),
            ),
          );
      await (db.delete(db.outboxEntries)
            ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
          .go();
      await _bumpConversationCursor(message, content);
      final current = await conversation(message.conversationId);
      if (current != null && message.seq < current.lastSeq &&
          pendingBefore?.clientMsgId == message.clientMsgId &&
          await _latestPending(message.conversationId) == null) {
        await _restoreServerPreview(current);
      }
    });
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
    await db.transaction(() async {
      final existing = await message(clientMsgId);
      if (existing == null) return;
      final nextSeq = existing.seq != null && (seq == null || existing.seq! > seq)
          ? existing.seq
          : seq;
      final confirmed = _confirmedStatuses.contains(status);
      await (db.update(db.localMessages)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .write(LocalMessagesCompanion(
        status: Value(_maxStatus(existing.status, status)),
        seq: Value(nextSeq),
      ));
      if (confirmed) {
        await (db.delete(db.outboxEntries)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .go();
      }
      final current = await conversation(existing.conversationId);
      if (current == null) return;
      final pending = await _latestPending(existing.conversationId);
      final latestKnownSeq = nextSeq != null && nextSeq > current.lastSeq
          ? nextSeq
          : current.lastSeq;
      if (latestKnownSeq != current.lastSeq) {
        await (db.update(db.localConversations)
              ..where((table) => table.id.equals(existing.conversationId)))
            .write(LocalConversationsCompanion(lastSeq: Value(latestKnownSeq)));
      }
      if (pending != null) {
        await _refreshPendingPreview(existing.conversationId);
      } else if (nextSeq != null && nextSeq >= current.lastSeq) {
        await (db.update(db.localConversations)
              ..where((table) => table.id.equals(existing.conversationId)))
            .write(LocalConversationsCompanion(
          lastMessagePreview: Value(_contentPreview(existing.type, existing.content)),
        ));
      } else if (nextSeq != null && existing.seq == null) {
        await _restoreServerPreview(current);
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
      final deleted = await message(clientMsgId);
      final pendingBefore = deleted == null ? null : await _latestPending(deleted.conversationId);
      await (db.delete(db.localMessages)..where((table) => table.clientMsgId.equals(clientMsgId)))
          .go();
      await (db.delete(db.outboxEntries)..where((table) => table.clientMsgId.equals(clientMsgId)))
          .go();
      if (deleted != null && pendingBefore?.clientMsgId == clientMsgId) {
        final pending = await _latestPending(deleted.conversationId);
        if (pending != null) {
          await _refreshPendingPreview(deleted.conversationId);
        } else {
          final current = await conversation(deleted.conversationId);
          if (current == null) return;
          await _restoreServerPreview(current);
        }
      } else if (deleted?.seq != null) {
        final current = await conversation(deleted!.conversationId);
        if (current != null && deleted.seq == current.lastSeq &&
            await _latestPending(deleted.conversationId) == null) {
          await _restoreServerPreview(current);
        }
      }
    });
  }

  Future<void> _restoreServerPreview(LocalConversation current) async {
    final latest = await (db.select(db.localMessages)
          ..where((table) => table.conversationId.equals(current.id) &
              table.seq.equals(current.lastSeq)))
        .getSingleOrNull();
    final preview = latest != null
        ? _contentPreview(latest.type, latest.content)
        : current.lastSeq == 0 ? null : 'Encrypted message';
    await (db.update(db.localConversations)..where((table) => table.id.equals(current.id)))
        .write(LocalConversationsCompanion(
          lastMessagePreview: Value(preview),
          updatedAt: latest == null ? const Value.absent() : Value(latest.createdAt),
        ));
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
    if (existing == null) return;
    final pending = await _latestPending(message.conversationId);
    final newest = message.createdAt.isAfter(existing.updatedAt)
        ? message.createdAt
        : existing.updatedAt;
    final lastSeq = message.seq > existing.lastSeq ? message.seq : existing.lastSeq;
    var preview = _safePreview(existing.lastMessagePreview);
    if (pending != null) {
      preview = _contentPreview(pending.type, pending.content);
    } else if (message.seq >= existing.lastSeq) {
      final incoming = _contentPreview(message.type, content);
      if (message.seq > existing.lastSeq || incoming != 'Encrypted message' ||
          preview == null || preview == 'Encrypted message') {
        preview = incoming;
      }
    }
    await (db.update(db.localConversations)
          ..where((table) => table.id.equals(message.conversationId)))
        .write(LocalConversationsCompanion(
      lastSeq: Value(lastSeq),
      updatedAt: Value(newest),
      lastMessagePreview: Value(preview),
    ));
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
