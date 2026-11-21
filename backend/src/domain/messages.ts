import { ApiError } from '../lib/errors.js';
import { withTransaction, type Db } from '../lib/db.js';
import type { Logger } from '../lib/logger.js';
import type { ScyllaMessageRepository } from './scylla-messages.js';

export type MessageRow = {
  id: string;
  conversation_id: string;
  seq: number;
  sender_id: string;
  client_msg_id: string;
  type: 'text' | 'image' | 'file';
  content: string;
  created_at: Date;
};

type RawMessageRow = Omit<MessageRow, 'seq'> & { seq: string | number };

const COLUMNS = `id, conversation_id, seq, sender_id, client_msg_id, type, content, created_at`;

function mapMessage(row: RawMessageRow): MessageRow {
  return { ...row, seq: Number(row.seq) };
}

export type StoredMessage = {
  message: MessageRow;
  duplicate: boolean;
};

/**
 * Optional wide-column store for the message table.
 *
 * When present, history reads (`page`, `sync`, `findBySeq`) are served from
 * Cassandra/ScyllaDB, which is the point of the Phase 4 migration: recent
 * message reads become a single-partition, `seq`-ordered slice instead of an
 * index scan.
 *
 * Postgres keeps three responsibilities that Scylla cannot replace without
 * losing a guarantee:
 * - `conversations.last_seq` allocation (gap-free, transactional);
 * - `UNIQUE (sender_id, client_msg_id)` idempotency;
 * - `message_receipts` foreign keys and the `search_vector` GIN index.
 * It therefore receives every row as a mirror during the transition. That
 * duplication is deliberate and is retired once search moves to a dedicated
 * engine (see docs/architecture.md).
 */
export type MessageStoreOptions = {
  scylla?: ScyllaMessageRepository | null;
  logger?: Logger;
};

/** Signals that the `seq` increment must be rolled back: a duplicate won. */
class ConcurrentDuplicate extends Error {
  constructor() {
    super('concurrent duplicate');
    this.name = 'ConcurrentDuplicate';
  }
}

export class MessageRepository {
  private readonly scylla: ScyllaMessageRepository | null;
  private readonly logger: Logger | null;

  constructor(
    private readonly db: Db,
    options: MessageStoreOptions = {},
  ) {
    this.scylla = options.scylla ?? null;
    this.logger = options.logger ?? null;
  }

  /** True when history reads are served by the wide-column store. */
  get usesWideColumnStore(): boolean {
    return this.scylla !== null;
  }

  /**
   * Allocates the next per-conversation `seq` and inserts the message in one
   * transaction. `UPDATE ... RETURNING` takes a row lock on the conversation,
   * so concurrent senders serialize and `seq` is gap-free and strictly
   * increasing.
   *
   * A repeated `client_msg_id` returns the original row untouched. The
   * increment and the insert must commit or roll back together: a CTE would
   * still bump `last_seq` when `ON CONFLICT DO NOTHING` skips the insert,
   * leaving a permanent hole in the sequence.
   */
  async append(input: {
    conversationId: string;
    senderId: string;
    clientMsgId: string;
    type: 'text' | 'image' | 'file';
    content: string;
  }): Promise<StoredMessage> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const existing = await this.findByClientId(input.senderId, input.clientMsgId);
      if (existing) return { message: existing, duplicate: true };

      try {
        const stored = await withTransaction(this.db, (client) =>
          this.insertNext(client, input),
        );
        if (stored) {
          await this.mirrorToScylla(stored);
          return { message: stored, duplicate: false };
        }
      } catch (error) {
        // A racing request with the same client_msg_id committed first. The
        // transaction rolled the seq increment back, so retry as a duplicate.
        if (error instanceof ConcurrentDuplicate) continue;
        // 23505: the unique (conversation_id, seq) or (sender_id, client_msg_id)
        // constraint was violated by a concurrent writer. Retry from the top.
        if ((error as { code?: string }).code !== '23505') throw error;
      }
    }

    const existing = await this.findByClientId(input.senderId, input.clientMsgId);
    if (!existing) {
      throw new ApiError('conflict', 'Message could not be stored');
    }
    return { message: existing, duplicate: true };
  }

  /**
   * Writes a committed message to the wide-column store after the Postgres
   * transaction succeeds.
   *
   * Ordering matters: Postgres is the source of truth for `seq`, so a Scylla
   * failure must not fail the send (the client already has a durable message).
   * A failed mirror is logged and recovered by the backfill script, which
   * replays from Postgres.
   */
  private async mirrorToScylla(message: MessageRow): Promise<void> {
    if (!this.scylla) return;
    try {
      await this.scylla.insert(message);
    } catch (error) {
      this.logger?.warn(
        { err: error, conversation_id: message.conversation_id, seq: message.seq },
        'scylla mirror write failed; message remains readable from postgres',
      );
    }
  }

  /**
   * Performs the increment + insert inside the caller's transaction. Throws
   * [ConcurrentDuplicate] when `ON CONFLICT` skipped the insert, so the seq
   * increment is rolled back instead of leaving a gap.
   */
  private async insertNext(
    client: import('pg').PoolClient,
    input: {
      conversationId: string;
      senderId: string;
      clientMsgId: string;
      type: 'text' | 'image' | 'file';
      content: string;
    },
  ): Promise<MessageRow | null> {
    const next = await client.query<{ last_seq: string }>(
      `UPDATE conversations SET last_seq = last_seq + 1
        WHERE id = $1
        RETURNING last_seq`,
      [input.conversationId],
    );
    if (!next.rows[0]) {
      throw new ApiError('conversation_not_found', 'Conversation not found');
    }

    const inserted = await client.query<RawMessageRow>(
      `INSERT INTO messages (conversation_id, seq, sender_id, client_msg_id, type, content)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (sender_id, client_msg_id) DO NOTHING
       RETURNING ${COLUMNS}`,
      [
        input.conversationId,
        Number(next.rows[0].last_seq),
        input.senderId,
        input.clientMsgId,
        input.type,
        input.content,
      ],
    );

    const row = inserted.rows[0];
    if (row) return mapMessage(row);
    // Signal the caller to roll back the seq increment it just made.
    throw new ConcurrentDuplicate();
  }

  async findByClientId(senderId: string, clientMsgId: string): Promise<MessageRow | null> {
    const { rows } = await this.db.query<RawMessageRow>(
      `SELECT ${COLUMNS} FROM messages
        WHERE sender_id = $1 AND client_msg_id = $2`,
      [senderId, clientMsgId],
    );
    return rows[0] ? mapMessage(rows[0]) : null;
  }

  /** Newest first; `before_seq` is exclusive so pages do not overlap. */
  async page(
    conversationId: string,
    limit: number,
    beforeSeq?: number,
  ): Promise<{ messages: MessageRow[]; hasMore: boolean }> {
    if (this.scylla) {
      return this.scylla.page(conversationId, limit, beforeSeq);
    }

    const params: unknown[] = [conversationId];
    let seqClause = '';
    if (beforeSeq !== undefined) {
      params.push(beforeSeq);
      seqClause = `AND seq < $${params.length}`;
    }
    params.push(limit + 1);

    const { rows } = await this.db.query<RawMessageRow>(
      `SELECT ${COLUMNS} FROM messages
        WHERE conversation_id = $1 ${seqClause}
        ORDER BY seq DESC
        LIMIT $${params.length}`,
      params,
    );

    return {
      messages: rows.slice(0, limit).map(mapMessage),
      hasMore: rows.length > limit,
    };
  }

  /** Offline catch-up: ascending from the caller's cursor, never the clock. */
  async sync(
    conversationId: string,
    afterSeq: number,
    limit: number,
  ): Promise<{ messages: MessageRow[]; latestSeq: number; hasMore: boolean }> {
    // `latest_seq` always comes from Postgres: `conversations.last_seq` is the
    // authoritative allocation counter and is never behind Scylla's mirror.
    const { rows: latest } = await this.db.query<{ last_seq: string }>(
      `SELECT last_seq FROM conversations WHERE id = $1`,
      [conversationId],
    );
    const latestSeq = Number(latest[0]?.last_seq ?? 0);

    if (this.scylla) {
      const page = await this.scylla.sync(conversationId, afterSeq, limit);
      return { messages: page.messages, latestSeq, hasMore: page.hasMore };
    }

    const { rows } = await this.db.query<RawMessageRow>(
      `SELECT ${COLUMNS} FROM messages
        WHERE conversation_id = $1 AND seq > $2
        ORDER BY seq ASC
        LIMIT $3`,
      [conversationId, afterSeq, limit + 1],
    );

    return {
      messages: rows.slice(0, limit).map(mapMessage),
      latestSeq,
      hasMore: rows.length > limit,
    };
  }

  /**
   * Full-text search over messages the caller can see. `conversationId`
   * narrows it to one thread (in-chat search); omit it for a global search
   * across every conversation the caller belongs to.
   *
   * The generated `search_vector` column is indexed with GIN, and
   * `websearch_to_tsquery` accepts the syntax users expect from search boxes
   * (quoted phrases, OR, leading minus) without throwing on stray punctuation.
   */
  async search(input: {
    userId: string;
    query: string;
    conversationId?: string;
    limit: number;
    beforeSeq?: number;
  }): Promise<{ messages: (MessageRow & { rank: number })[]; hasMore: boolean }> {
    const params: unknown[] = [input.userId, input.query];
    const clauses: string[] = [];

    if (input.conversationId) {
      params.push(input.conversationId);
      clauses.push(`m.conversation_id = $${params.length}`);
    }
    if (input.beforeSeq !== undefined) {
      params.push(input.beforeSeq);
      clauses.push(`m.seq < $${params.length}`);
    }
    params.push(input.limit + 1);

    const { rows } = await this.db.query<RawMessageRow & { rank: number }>(
      `SELECT ${COLUMNS.split(', ')
        .map((column) => `m.${column.trim()}`)
        .join(', ')}, ts_rank(m.search_vector, tsq)::float8 AS rank
         FROM messages m
         JOIN conversation_members cm
           ON cm.conversation_id = m.conversation_id AND cm.user_id = $1
         CROSS JOIN LATERAL websearch_to_tsquery('simple', $2) AS tsq
        WHERE m.search_vector @@ tsq
          ${clauses.map((clause) => `AND ${clause}`).join('\n          ')}
        ORDER BY rank DESC, m.seq DESC
        LIMIT $${params.length}`,
      params,
    );

    return {
      messages: rows.slice(0, input.limit).map((row) => ({ ...mapMessage(row), rank: row.rank })),
      hasMore: rows.length > input.limit,
    };
  }

  async findBySeq(conversationId: string, seq: number): Promise<MessageRow | null> {
    if (this.scylla) {
      return this.scylla.findBySeq(conversationId, seq);
    }
    const { rows } = await this.db.query<RawMessageRow>(
      `SELECT ${COLUMNS} FROM messages WHERE conversation_id = $1 AND seq = $2`,
      [conversationId, seq],
    );
    return rows[0] ? mapMessage(rows[0]) : null;
  }

  /** Records a `delivered` receipt for the message at `seq`, if it exists. */
  async markDeliveredBySeq(
    conversationId: string,
    seq: number,
    userId: string,
  ): Promise<MessageRow | null> {
    const message = await this.findBySeq(conversationId, seq);
    if (!message) return null;

    await this.db.query(
      `INSERT INTO message_receipts (message_id, user_id, status)
       VALUES ($1, $2, 'delivered')
       ON CONFLICT (message_id, user_id) DO NOTHING`,
      [message.id, userId],
    );
    return message;
  }

  /**
   * Read cursors live on `conversation_members.last_read_seq`. `GREATEST`
   * makes replays and out-of-order acks harmless.
   */
  async markRead(conversationId: string, userId: string, seq: number): Promise<number> {
    const { rows } = await this.db.query<{ last_read_seq: string }>(
      `UPDATE conversation_members
          SET last_read_seq = GREATEST(last_read_seq, $3)
        WHERE conversation_id = $1 AND user_id = $2
        RETURNING last_read_seq`,
      [conversationId, userId, seq],
    );
    if (!rows[0]) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
    return Number(rows[0].last_read_seq);
  }
}
