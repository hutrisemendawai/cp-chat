import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../account/account_scope.dart';
import '../crypto/e2ee_service.dart' show isEncryptedContent, undecryptableContent;
import '../models/models.dart';
import 'app_database.dart';

/// Display hints for a conversation the client has never seen, carried by a live
/// `message` frame or a data-only push.
///
/// Used to insert a provisional `local_conversations` row in the same
/// transaction as the message, so the chat list updates immediately instead of
/// waiting for the authoritative `GET /api/v1/conversations/:id` hydration.
class ProvisionalConversationHint {
  const ProvisionalConversationHint({
    this.type = 'direct',
    this.conversationName,
    this.peerId,
    this.peerName,
    this.peerAvatarUrl,
  });

  final String type;
  final String? conversationName;
  final String? peerId;
  final String? peerName;
  final String? peerAvatarUrl;
}

/// Local mirror of server state plus the outbox for unsent messages.
///
/// Every write is idempotent: the server is authoritative, and the same row can
/// arrive from a live `message` event, a REST sync, or the optimistic local
/// insert, in any order.
///
/// When bound to an [AccountScope], every write checks `scope.isOpen` and
/// gracefully drops late work arriving after logout/teardown closes the DB.
class ChatDao {
  ChatDao(this.db, {this.scope});

  final AppDatabase db;
  final AccountScope? scope;

  bool get _closed => db.isClosed || (scope != null && !scope!.isOpen);

  Future<T?> _guard<T>(Future<T> Function() action) async {
    if (_closed) return null;
    try {
      return await action();
    } catch (error) {
      if (_isClosedError(error)) return null;
      rethrow;
    }
  }

  static bool _isClosedError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('closed') || text.contains('database has been closed');
  }

  Stream<List<LocalConversation>> watchConversations() {
    if (_closed) return const Stream<List<LocalConversation>>.empty();
    return (db.select(db.localConversations)
          ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)]))
        .watch();
  }

  Future<List<LocalConversation>> conversations() async {
    return await _guard(
          () => (db.select(db.localConversations)
                ..orderBy([(table) => OrderingTerm.desc(table.updatedAt)]))
              .get(),
        ) ??
        const [];
  }

  Stream<LocalConversation?> watchConversation(String id) {
    if (_closed) return const Stream<LocalConversation?>.empty();
    return (db.select(db.localConversations)..where((table) => table.id.equals(id)))
        .watchSingleOrNull();
  }

  Future<LocalConversation?> conversation(String id) async {
    return _guard<LocalConversation?>(
      () => (db.select(db.localConversations)..where((table) => table.id.equals(id)))
          .getSingleOrNull(),
    );
  }

  Stream<List<LocalMessage>> watchMessages(String conversationId) {
    if (_closed) return const Stream<List<LocalMessage>>.empty();
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
  Future<LocalMessage?> message(String clientMsgId) async {
    return _guard<LocalMessage?>(
      () => (db.select(db.localMessages)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .getSingleOrNull(),
    );
  }

  /// Looks up a persisted message by `(conversationId, seq)`.
  Future<LocalMessage?> messageBySeq(String conversationId, int seq) async {
    return _guard<LocalMessage?>(
      () => (db.select(db.localMessages)
            ..where((table) =>
                table.conversationId.equals(conversationId) &
                table.seq.equals(seq)))
          .getSingleOrNull(),
    );
  }

  Future<int> localMaxSeq(String conversationId) async {
    final result = await _guard(() async {
      final row = await (db.selectOnly(db.localMessages)
            ..addColumns([db.localMessages.seq.max()])
            ..where(db.localMessages.conversationId.equals(conversationId)))
          .getSingle();
      return row.read(db.localMessages.seq.max()) ?? 0;
    });
    return result ?? 0;
  }

  /// Persisted `cleared_seq` watermark for [conversationId] (0 if never cleared).
  Future<int> clearedSeqFor(String conversationId) async {
    final row = await conversation(conversationId);
    return row?.clearedSeq ?? 0;
  }

  /// Effective sync cursor for [conversationId]: `max(localMaxSeq, clearedSeq)`.
  ///
  /// After a history clear or key rotation, local messages are gone (`localMaxSeq == 0`)
  /// while `clearedSeq > 0`, so sync starts at `clearedSeq` instead of 0 and accepts
  /// the first post-clear message at `seq = clearedSeq + 1`.
  Future<int> effectiveCursor(String conversationId) async {
    final maxLocal = await localMaxSeq(conversationId);
    final cleared = await clearedSeqFor(conversationId);
    return math.max(maxLocal, cleared);
  }

  /// Highest `seq` received from anyone other than `selfId`. The read cursor is
  /// built from this so reading your own messages never generates an ack.
  Future<int> latestSeqFromOthers(String conversationId, String selfId) async {
    final result = await _guard(() async {
      final row = await (db.selectOnly(db.localMessages)
            ..addColumns([db.localMessages.seq.max()])
            ..where(
              db.localMessages.conversationId.equals(conversationId) &
                  db.localMessages.senderId.equals(selfId).not(),
            ))
          .getSingle();
      return row.read(db.localMessages.seq.max()) ?? 0;
    });
    return result ?? 0;
  }

  /// Replaces the conversation list from a fresh server response. Direct
  /// conversations have no server-side name, so the peer's name is cached for
  /// display and cheap sorting without refetching members.
  Future<void> upsertConversations(List<Conversation> conversations, {String? selfId}) async {
    await _guard(() async {
      await db.transaction(() async {
        for (final item in conversations) {
          if (_closed) return;
          await _upsertConversation(item, selfId: selfId);
        }
      });
    });
  }

  Future<void> upsertConversation(
    Conversation conversation, {
    bool preserveLocalCursor = true,
    String? selfId,
  }) async {
    await _guard(() async {
      await db.transaction(() => _upsertConversation(
            conversation,
            preserveLocalCursor: preserveLocalCursor,
            selfId: selfId,
          ));
    });
  }

  Future<void> _upsertConversation(
    Conversation item, {
    bool preserveLocalCursor = true,
    String? selfId,
  }) async {
    final existing = await (db.select(db.localConversations)
          ..where((table) => table.id.equals(item.id)))
        .getSingleOrNull();
    final effectiveClearedSeq = math.max(existing?.clearedSeq ?? 0, item.clearedSeq);

    // If the server watermark moved ahead of local history, prune cleared rows.
    if (effectiveClearedSeq > (existing?.clearedSeq ?? 0)) {
      await (db.delete(db.localMessages)
            ..where(
              (table) =>
                  table.conversationId.equals(item.id) &
                  table.seq.isNotNull() &
                  table.seq.isSmallerOrEqualValue(effectiveClearedSeq),
            ))
          .go();
    }

    final pending = await _latestPending(item.id);
    final summary = item.lastMessage;
    final summarySeq = summary?.seq ?? item.lastSeq;
    final stale = existing != null &&
        preserveLocalCursor &&
        (item.lastSeq < existing.lastSeq ||
            (summary != null && summarySeq < existing.lastSeq));
    String? preview;
    if (pending != null) {
      preview = _contentPreview(pending.type, pending.content);
    } else if (stale) {
      // A summary captured before live WS messages landed must not regress the
      // already-decrypted preview back to empty.
      preview = _safePreview(existing.lastMessagePreview);
    } else if (summary == null && effectiveClearedSeq >= item.lastSeq) {
      // Cleared conversation with no newer messages: empty preview.
      preview = null;
    } else if (summary == null) {
      preview = null;
    } else if (summary.seq <= effectiveClearedSeq) {
      preview = null;
    } else {
      preview = await _summaryPreview(item.id, summary);
      if (preview == 'Encrypted message' &&
          existing != null &&
          item.lastSeq == existing.lastSeq &&
          summary.seq == item.lastSeq &&
          existing.lastMessagePreview != null &&
          !await _hasConflictingMessage(item.id, summary)) {
        preview = _safePreview(existing.lastMessagePreview);
      }
    }
    final serverTime = summary?.createdAt ?? item.createdAt;
    var updatedAt = serverTime;
    if (existing != null &&
        preserveLocalCursor &&
        (stale || pending != null) &&
        existing.updatedAt.isAfter(updatedAt)) {
      updatedAt = existing.updatedAt;
    }
    if (pending != null && pending.createdAt.isAfter(updatedAt)) {
      updatedAt = pending.createdAt;
    }
    final lastSeq = preserveLocalCursor && existing != null && existing.lastSeq > item.lastSeq
        ? existing.lastSeq
        : item.lastSeq;
    // Preserve a newer local read cursor: a stale REST summary must never move
    // it backwards, otherwise an already-read chat regains an unread badge.
    final lastReadSeq = math.max(
      preserveLocalCursor && existing != null ? existing.lastReadSeq : 0,
      math.max(item.lastReadSeq, effectiveClearedSeq),
    );
    final int unreadCount;
    if (effectiveClearedSeq >= lastSeq || lastReadSeq >= lastSeq) {
      unreadCount = 0;
    } else if (stale) {
      // The summary predates live WS messages already persisted locally.
      unreadCount = math.max(existing.unreadCount, item.unreadCount);
    } else {
      unreadCount = item.unreadCount;
    }
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
            lastReadSeq: Value(lastReadSeq),
            clearedSeq: Value(effectiveClearedSeq),
            unreadCount: Value(unreadCount),
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
    final byId = await (db.select(db.localMessages)
          ..where((table) => table.clientMsgId.equals(summary.clientMsgId)))
        .getSingleOrNull();
    if (byId != null &&
        byId.conversationId == conversationId &&
        (byId.seq == null || byId.seq == summary.seq) &&
        byId.type == 'text' &&
        !_isUnreadable(byId.content)) {
      return byId.content;
    }
    final bySeq = await (db.select(db.localMessages)
          ..where((table) =>
              table.conversationId.equals(conversationId) &
              table.seq.equals(summary.seq)))
        .getSingleOrNull();
    if (bySeq != null && bySeq.type == 'text' && !_isUnreadable(bySeq.content)) {
      return bySeq.content;
    }
    return 'Encrypted message';
  }

  Future<bool> _hasConflictingMessage(String conversationId, Message summary) async {
    final row = await (db.select(db.localMessages)
          ..where((table) =>
              table.conversationId.equals(conversationId) &
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
  Future<void> enqueueOutgoing({
    required String clientMsgId,
    required String conversationId,
    required String senderId,
    required String type,
    required String content,
    String? wireContent,
    required DateTime createdAt,
  }) async {
    await _guard(() async {
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
    });
  }

  Future<void> _refreshPendingPreview(String conversationId) async {
    final existing = await (db.select(db.localConversations)
          ..where((table) => table.id.equals(conversationId)))
        .getSingleOrNull();
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
  /// [ensureConversation] inserts a provisional conversation row atomically with
  /// the message when the client has never seen this conversation, so an inbound
  /// message from a new peer is never an orphaned row (`watchConversations()`
  /// emits immediately). [incrementUnread] book-keeps the unread badge for a
  /// message from someone else while this chat is not the one on screen.
  Future<void> upsertServerMessage(
    Message message, {
    String status = 'sent',
    ProvisionalConversationHint? ensureConversation,
    bool incrementUnread = false,
  }) async {
    await _guard(() async {
      await db.transaction(() async {
        final conv = await (db.select(db.localConversations)
              ..where((table) => table.id.equals(message.conversationId)))
            .getSingleOrNull();
        // Never re-insert messages at or below this member's cleared watermark.
        if (conv != null && message.seq <= conv.clearedSeq) return;

        final existing = await (db.select(db.localMessages)
              ..where((table) => table.clientMsgId.equals(message.clientMsgId)))
            .getSingleOrNull();
        if (existing != null && existing.conversationId != message.conversationId) {
          throw StateError('Message id belongs to another conversation');
        }
        // Only a genuinely new inbound row counts as unread; a sync replay of an
        // already-stored row must never double-increment the badge.
        final isNewIncomingRow = existing == null || existing.seq == null;
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
        await _bumpConversationCursor(
          message,
          content,
          ensureConversation: ensureConversation,
          incrementUnread: incrementUnread && isNewIncomingRow,
        );
        final current = await (db.select(db.localConversations)
              ..where((table) => table.id.equals(message.conversationId)))
            .getSingleOrNull();
        if (current != null &&
            message.seq < current.lastSeq &&
            pendingBefore?.clientMsgId == message.clientMsgId &&
            await _latestPending(message.conversationId) == null) {
          await _restoreServerPreview(current);
        }
      });
    });
  }

  Future<void> upsertServerMessages(List<Message> messages) async {
    for (final message in messages) {
      if (_closed) return;
      await upsertServerMessage(message);
    }
  }

  /// Stores a synthetic local system row (e.g. collapsed "Secure session reset"
  /// notice) without an outbox entry or server seq collision.
  Future<void> upsertSystemNotice({
    required String clientMsgId,
    required String conversationId,
    required String content,
    required DateTime createdAt,
    int? seq,
  }) async {
    await _guard(() async {
      await db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              clientMsgId: clientMsgId,
              id: Value(clientMsgId),
              conversationId: conversationId,
              seq: Value(seq),
              senderId: 'system',
              type: 'system',
              content: content,
              createdAt: createdAt,
              status: const Value('sent'),
            ),
          );
    });
  }

  Future<void> applyStatus(String clientMsgId, String status, {int? seq}) async {
    await _guard(() async {
      await db.transaction(() async {
        final existing = await (db.select(db.localMessages)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .getSingleOrNull();
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
        final current = await (db.select(db.localConversations)
              ..where((table) => table.id.equals(existing.conversationId)))
            .getSingleOrNull();
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
    });
  }

  Future<void> applyReadReceipt({
    required String conversationId,
    required String selfId,
    required int upToSeq,
    required int readCount,
    required int memberCount,
  }) async {
    await _guard(() async {
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
    });
  }

  Future<String?> conversationType(String conversationId) async {
    final row = await conversation(conversationId);
    return row?.type;
  }

  Future<void> markFailed(String clientMsgId) async {
    await _guard(() async {
      await (db.update(db.localMessages)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .write(const LocalMessagesCompanion(status: Value('failed')));
    });
  }

  Future<void> markPending(String clientMsgId) async {
    await _guard(() async {
      await (db.update(db.localMessages)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .write(const LocalMessagesCompanion(status: Value('pending')));
    });
  }

  Future<void> deleteMessage(String clientMsgId) async {
    await _guard(() async {
      await db.transaction(() async {
        final deleted = await (db.select(db.localMessages)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .getSingleOrNull();
        final pendingBefore =
            deleted == null ? null : await _latestPending(deleted.conversationId);
        await (db.delete(db.localMessages)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .go();
        await (db.delete(db.outboxEntries)
              ..where((table) => table.clientMsgId.equals(clientMsgId)))
            .go();
        if (deleted != null && pendingBefore?.clientMsgId == clientMsgId) {
          final pending = await _latestPending(deleted.conversationId);
          if (pending != null) {
            await _refreshPendingPreview(deleted.conversationId);
          } else {
            final current = await (db.select(db.localConversations)
                  ..where((table) => table.id.equals(deleted.conversationId)))
                .getSingleOrNull();
            if (current == null) return;
            await _restoreServerPreview(current);
          }
        } else if (deleted?.seq != null) {
          final current = await (db.select(db.localConversations)
                ..where((table) => table.id.equals(deleted!.conversationId)))
              .getSingleOrNull();
          if (current != null &&
              deleted!.seq == current.lastSeq &&
              await _latestPending(deleted.conversationId) == null) {
            await _restoreServerPreview(current);
          }
        }
      });
    });
  }

  Future<void> _restoreServerPreview(LocalConversation current) async {
    final latest = await (db.select(db.localMessages)
          ..where((table) =>
              table.conversationId.equals(current.id) &
              table.seq.equals(current.lastSeq)))
        .getSingleOrNull();
    final preview = latest != null
        ? _contentPreview(latest.type, latest.content)
        : (current.lastSeq <= current.clearedSeq || current.lastSeq == 0)
            ? null
            : 'Encrypted message';
    await (db.update(db.localConversations)..where((table) => table.id.equals(current.id)))
        .write(LocalConversationsCompanion(
          lastMessagePreview: Value(preview),
          updatedAt: latest == null ? const Value.absent() : Value(latest.createdAt),
        ));
  }

  Future<List<OutboxEntry>> pendingOutbox() async {
    return await _guard(() async {
          final rows = await db.select(db.outboxEntries).get();
          rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return rows;
        }) ??
        const [];
  }

  Future<void> recordAttempt(String clientMsgId) async {
    await _guard(() async {
      await (db.update(db.outboxEntries)
            ..where((table) => table.clientMsgId.equals(clientMsgId)))
          .write(
        OutboxEntriesCompanion(
          attempts: Value(await _attemptCount(clientMsgId)),
          lastAttemptAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  Future<int> _attemptCount(String clientMsgId) async {
    final row = await (db.select(db.outboxEntries)
          ..where((table) => table.clientMsgId.equals(clientMsgId)))
        .getSingleOrNull();
    return (row?.attempts ?? 0) + 1;
  }

  Future<void> setReadCursor(String conversationId, int seq) async {
    await _guard(() async {
      final existing = await (db.select(db.localConversations)
            ..where((table) => table.id.equals(conversationId)))
          .getSingleOrNull();
      if (existing == null) return;
      if (seq <= existing.lastReadSeq) return;

      await (db.update(db.localConversations)
            ..where((table) => table.id.equals(conversationId)))
          .write(LocalConversationsCompanion(lastReadSeq: Value(seq)));
    });
  }

  Future<void> clearUnread(String conversationId) async {
    await _guard(() async {
      await (db.update(db.localConversations)
            ..where((table) => table.id.equals(conversationId)))
          .write(const LocalConversationsCompanion(unreadCount: Value(0)));
    });
  }

  /// L1 per-conversation clear: drops local messages, outbox, and drafts for
  /// [conversationId] and advances its local `clearedSeq` floor monotonically.
  Future<void> clearConversationRows(
    String conversationId, {
    required int clearedSeq,
  }) async {
    await _guard(() async {
      await db.transaction(() async {
        await (db.delete(db.outboxEntries)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        await (db.delete(db.localMessages)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        await (db.delete(db.drafts)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();

        final existing = await (db.select(db.localConversations)
              ..where((table) => table.id.equals(conversationId)))
            .getSingleOrNull();
        if (existing != null) {
          final nextCleared = math.max(existing.clearedSeq, clearedSeq);
          final nextRead = math.max(existing.lastReadSeq, nextCleared);
          final nextLast = math.max(existing.lastSeq, nextCleared);
          await (db.update(db.localConversations)
                ..where((table) => table.id.equals(conversationId)))
              .write(LocalConversationsCompanion(
            clearedSeq: Value(nextCleared),
            lastReadSeq: Value(nextRead),
            lastSeq: Value(nextLast),
            unreadCount: const Value(0),
            lastMessagePreview: const Value(null),
          ));
        }
      });
    });
  }

  /// Applies a server-confirmed `cleared_seq` watermark (from REST clear, sync,
  /// or `history_cleared` WebSocket frame): advances `clearedSeq` monotonically
  /// and prunes any local rows at or below the watermark while keeping newer
  /// messages intact.
  Future<void> applyClearedSeq(String conversationId, int clearedSeq) async {
    if (clearedSeq <= 0) return;
    await _guard(() async {
      await db.transaction(() async {
        final existing = await (db.select(db.localConversations)
              ..where((table) => table.id.equals(conversationId)))
            .getSingleOrNull();
        final nextCleared = math.max(existing?.clearedSeq ?? 0, clearedSeq);

        await (db.delete(db.localMessages)
              ..where(
                (table) =>
                    table.conversationId.equals(conversationId) &
                    table.seq.isNotNull() &
                    table.seq.isSmallerOrEqualValue(nextCleared),
              ))
            .go();

        if (existing != null) {
          final nextRead = math.max(existing.lastReadSeq, nextCleared);
          final nextLast = math.max(existing.lastSeq, nextCleared);
          final clearedAll = nextLast <= nextCleared;
          await (db.update(db.localConversations)
                ..where((table) => table.id.equals(conversationId)))
              .write(LocalConversationsCompanion(
            clearedSeq: Value(nextCleared),
            lastReadSeq: Value(nextRead),
            lastSeq: Value(nextLast),
            unreadCount: clearedAll ? const Value(0) : Value(existing.unreadCount),
            lastMessagePreview: clearedAll ? const Value(null) : const Value.absent(),
          ));
        }
      });
    });
  }

  /// L1 clear-all: removes all messages, outbox entries, and drafts while
  /// keeping conversation shells with `clearedSeq = max(clearedSeq, lastSeq)`
  /// so an offline clear never allows older rows to re-sync before the server
  /// call completes.
  Future<void> clearAllHistoryKeepWatermarks() async {
    await _guard(() async {
      await db.transaction(() async {
        await db.delete(db.outboxEntries).go();
        await db.delete(db.localMessages).go();
        await db.delete(db.drafts).go();
        final convs = await db.select(db.localConversations).get();
        for (final conv in convs) {
          final floor = math.max(conv.clearedSeq, conv.lastSeq);
          await (db.update(db.localConversations)
                ..where((table) => table.id.equals(conv.id)))
              .write(LocalConversationsCompanion(
            clearedSeq: Value(floor),
            lastReadSeq: Value(math.max(conv.lastReadSeq, floor)),
            unreadCount: const Value(0),
            lastMessagePreview: const Value(null),
          ));
        }
      });
    });
  }

  /// Drops a conversation and its messages locally, e.g. after leaving a group.
  Future<void> deleteConversation(String conversationId) async {
    await _guard(() async {
      await db.transaction(() async {
        await (db.delete(db.outboxEntries)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        await (db.delete(db.localMessages)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        await (db.delete(db.drafts)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        await (db.delete(db.localConversations)
              ..where((table) => table.id.equals(conversationId)))
            .go();
      });
    });
  }

  /// Removes all chat rows in this account database (kept for L1/tests;
  /// **never** called on logout).
  Future<void> clearAll() async {
    await _guard(() async {
      await db.transaction(() async {
        await db.delete(db.outboxEntries).go();
        await db.delete(db.localMessages).go();
        await db.delete(db.drafts).go();
        await db.delete(db.localConversations).go();
      });
    });
  }

  /// Reads an unsent composer draft for [conversationId].
  Future<String?> readDraft(String conversationId) async {
    final row = await _guard<Draft?>(
      () => (db.select(db.drafts)
            ..where((table) => table.conversationId.equals(conversationId)))
          .getSingleOrNull(),
    );
    return row?.body;
  }

  /// Saves or clears a composer draft for [conversationId].
  Future<void> saveDraft(String conversationId, String body) async {
    await _guard(() async {
      if (body.trim().isEmpty) {
        await (db.delete(db.drafts)
              ..where((table) => table.conversationId.equals(conversationId)))
            .go();
        return;
      }
      await db.into(db.drafts).insertOnConflictUpdate(
            DraftsCompanion.insert(
              conversationId: conversationId,
              body: body,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
    });
  }

  Future<void> _bumpConversationCursor(
    Message message,
    String content, {
    ProvisionalConversationHint? ensureConversation,
    bool incrementUnread = false,
  }) async {
    final existing = await (db.select(db.localConversations)
          ..where((table) => table.id.equals(message.conversationId)))
        .getSingleOrNull();
    if (existing == null) {
      if (ensureConversation == null) return;
      // No local conversation yet (first contact from a non-friend): insert a
      // provisional row in the same transaction as the message so the chat list
      // is never left with an orphaned message row.
      final isGroup = ensureConversation.type == 'group';
      await db.into(db.localConversations).insertOnConflictUpdate(
            LocalConversationsCompanion.insert(
              id: message.conversationId,
              type: ensureConversation.type,
              name: Value(isGroup ? ensureConversation.conversationName : null),
              peerId: Value(isGroup ? null : ensureConversation.peerId),
              peerName: Value(isGroup ? null : ensureConversation.peerName),
              peerAvatarUrl: Value(isGroup ? null : ensureConversation.peerAvatarUrl),
              lastMessagePreview: Value(_contentPreview(message.type, content)),
              lastSeq: Value(message.seq),
              lastReadSeq: const Value(0),
              clearedSeq: const Value(0),
              unreadCount: Value(incrementUnread ? 1 : 0),
              updatedAt: message.createdAt,
            ),
          );
      return;
    }
    final pending = await _latestPending(message.conversationId);
    final newest = message.createdAt.isAfter(existing.updatedAt)
        ? message.createdAt
        : existing.updatedAt;
    final lastSeq = message.seq > existing.lastSeq ? message.seq : existing.lastSeq;
    // A message at or below the read/cleared watermark is already read; a newer
    // message from the peer bumps the badge.
    final bumpedUnread =
        incrementUnread && message.seq > math.max(existing.lastReadSeq, existing.clearedSeq);
    final nextUnread = bumpedUnread ? existing.unreadCount + 1 : existing.unreadCount;
    var preview = _safePreview(existing.lastMessagePreview);
    if (pending != null) {
      preview = _contentPreview(pending.type, pending.content);
    } else if (message.seq >= existing.lastSeq) {
      final incoming = _contentPreview(message.type, content);
      if (message.seq > existing.lastSeq ||
          incoming != 'Encrypted message' ||
          preview == null ||
          preview == 'Encrypted message') {
        preview = incoming;
      }
    }
    await (db.update(db.localConversations)
          ..where((table) => table.id.equals(message.conversationId)))
        .write(LocalConversationsCompanion(
      lastSeq: Value(lastSeq),
      updatedAt: Value(newest),
      lastMessagePreview: Value(preview),
      unreadCount: Value(nextUnread),
    ));
  }
}

/// States assigned by the server, which prove it accepted the message.
const _confirmedStatuses = {'sent', 'delivered', 'read'};

const _statusOrder = {'pending': 0, 'sent': 1, 'delivered': 2, 'read': 3, 'failed': 4};

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
