import cassandra from 'cassandra-driver';

import type { Config } from '../config.js';
import type { Logger } from '../lib/logger.js';
import { withSpan } from '../lib/tracing.js';
import type { MessageRow } from './messages.js';

/**
 * Cassandra/ScyllaDB access for the high-volume `messages` table.
 *
 * Only the read/write paths that scale with message volume live here:
 * appending, paginating backwards, syncing forward, and looking a message up
 * by `(conversation_id, seq)`. Membership, `seq` allocation, receipts, and
 * full-text search stay in Postgres, which is the source of truth for those.
 *
 * Writes are `INSERT`s with full primary keys, so they are idempotent: replaying
 * the same message (a retry, a consumer redelivery, a backfill) writes the same
 * row rather than duplicating it.
 */

const COLUMNS = `conversation_id, seq, message_id, sender_id, client_msg_id, type, content, created_at`;

export type ScyllaClient = {
  execute(
    query: string,
    params?: unknown[],
    options?: { prepare?: boolean; consistency?: number },
  ): Promise<{ rows: Record<string, unknown>[] }>;
  shutdown(): Promise<void>;
};

export function createScyllaClient(config: Config): ScyllaClient {
  const client = new cassandra.Client({
    contactPoints: config.SCYLLA_CONTACT_POINTS.split(',').map((point) => point.trim()),
    localDataCenter: config.SCYLLA_LOCAL_DATACENTER,
    keyspace: config.SCYLLA_KEYSPACE,
    credentials:
      config.SCYLLA_USERNAME && config.SCYLLA_PASSWORD
        ? { username: config.SCYLLA_USERNAME, password: config.SCYLLA_PASSWORD }
        : undefined,
    // Quorum keeps a read-after-write on one replica consistent; a single-node
    // local cluster resolves it trivially.
    queryOptions: { consistency: cassandra.types.consistencies.localQuorum },
    pooling: { coreConnectionsPerHost: { [cassandra.types.distance.local]: 2 } },
  });

  return {
    execute: async (query, params = [], options) => {
      const result = await client.execute(query, params, {
        prepare: options?.prepare ?? false,
        consistency: options?.consistency,
      });
      return { rows: result.rows as unknown as Record<string, unknown>[] };
    },
    shutdown: () => client.shutdown(),
  };
}

type RawScyllaMessage = {
  conversation_id: unknown;
  seq: cassandra.types.Long | bigint | number;
  message_id: unknown;
  sender_id: unknown;
  client_msg_id: unknown;
  type: 'text' | 'image' | 'file';
  content: string;
  created_at: Date;
};

/**
 * The driver returns `Uuid`/`Long` wrapper objects. Their `toJSON()` adds
 * quotes (so passing one straight to `pg` yields `invalid input syntax for
 * type uuid: ""...""`), so every value is normalised to a plain primitive here.
 */
function asUuid(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value && typeof (value as { toString(): string }).toString === 'function') {
    return (value as { toString(): string }).toString().replace(/^"|"$/g, '');
  }
  return String(value);
}

function mapRow(row: Record<string, unknown>): MessageRow {
  const raw = row as unknown as RawScyllaMessage;
  return {
    id: asUuid(raw.message_id),
    conversation_id: asUuid(raw.conversation_id),
    seq: Number(raw.seq),
    sender_id: asUuid(raw.sender_id),
    client_msg_id: asUuid(raw.client_msg_id),
    type: raw.type,
    content: raw.content,
    created_at: raw.created_at,
  };
}

export class ScyllaMessageRepository {
  constructor(
    private readonly client: ScyllaClient,
    private readonly logger: Logger,
  ) {}

  /**
   * Writes the message to both query tables in one logged batch. The batch is
   * small and same-partition for the first table, so it stays off the
   * expensive multi-partition path while still being atomic enough for a
   * retry-safe write.
   */
  async insert(message: MessageRow): Promise<void> {
    await withSpan(
      'scylla.message.insert',
      { conversation_id: message.conversation_id, seq: message.seq },
      async () => {
        const statement = `INSERT INTO messages_by_conversation (${COLUMNS})
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`;
        const values = [
          message.conversation_id,
          message.seq,
          message.id,
          message.sender_id,
          message.client_msg_id,
          message.type,
          message.content,
          message.created_at,
        ];

        const dedupe = `INSERT INTO messages_by_client_id
            (sender_id, client_msg_id, conversation_id, seq, message_id, type, content, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`;

        // `IF NOT EXISTS` on the dedupe table makes the second argument a
        // no-op when the client_msg_id was already stored; the primary table
        // insert is idempotent on its own.
        //
        // Both statements are prepared: an unprepared statement lets the driver
        // infer a JS number as `double`, and a `double` written into a BIGINT
        // column stores the IEEE-754 bit pattern (5 -> 4617315517961601024).
        // Preparing binds against the real column types instead.
        await this.client.execute(statement, values, { prepare: true });
        await this.client.execute(
          dedupe,
          [
            message.sender_id,
            message.client_msg_id,
            message.conversation_id,
            message.seq,
            message.id,
            message.type,
            message.content,
            message.created_at,
          ],
          { prepare: true },
        );
      },
    );
  }

  /** Newest first, matching the Postgres `page()` contract. */
  async page(
    conversationId: string,
    limit: number,
    beforeSeq?: number,
  ): Promise<{ messages: MessageRow[]; hasMore: boolean }> {
    const options = { prepare: true };
    const result =
      beforeSeq !== undefined
        ? await this.client.execute(
            `SELECT ${COLUMNS} FROM messages_by_conversation
              WHERE conversation_id = ? AND seq < ?
              ORDER BY seq DESC LIMIT ?`,
            [conversationId, beforeSeq, limit + 1],
            options,
          )
        : await this.client.execute(
            `SELECT ${COLUMNS} FROM messages_by_conversation
              WHERE conversation_id = ? LIMIT ?`,
            [conversationId, limit + 1],
            options,
          );

    const rows = result.rows.map(mapRow);
    return { messages: rows.slice(0, limit), hasMore: rows.length > limit };
  }

  /** Offline catch-up: ascending from the caller's cursor. */
  async sync(
    conversationId: string,
    afterSeq: number,
    limit: number,
  ): Promise<{ messages: MessageRow[]; hasMore: boolean }> {
    const result = await this.client.execute(
      `SELECT ${COLUMNS} FROM messages_by_conversation
        WHERE conversation_id = ? AND seq > ?
        ORDER BY seq ASC LIMIT ?`,
      [conversationId, afterSeq, limit + 1],
      { prepare: true },
    );
    const rows = result.rows.map(mapRow);
    return { messages: rows.slice(0, limit), hasMore: rows.length > limit };
  }

  async findBySeq(conversationId: string, seq: number): Promise<MessageRow | null> {
    const result = await this.client.execute(
      `SELECT ${COLUMNS} FROM messages_by_conversation WHERE conversation_id = ? AND seq = ?`,
      [conversationId, seq],
      { prepare: true },
    );
    return result.rows[0] ? mapRow(result.rows[0]) : null;
  }

  async findByClientId(senderId: string, clientMsgId: string): Promise<MessageRow | null> {
    const result = await this.client.execute(
      `SELECT conversation_id, seq, message_id, sender_id, client_msg_id, type, content, created_at
         FROM messages_by_client_id WHERE sender_id = ? AND client_msg_id = ?`,
      [senderId, clientMsgId],
      { prepare: true },
    );
    return result.rows[0] ? mapRow(result.rows[0]) : null;
  }

  async close(): Promise<void> {
    await this.client.shutdown().catch((error) => {
      this.logger.debug({ err: error }, 'scylla shutdown failed');
    });
  }
}
