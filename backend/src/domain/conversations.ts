import { ApiError } from '../lib/errors.js';
import type { Db, PoolClient } from '../lib/db.js';
import { directKey } from '../lib/ids.js';
import { toPublicUser, type PublicUser, type UserRow } from './users.js';

export type ConversationRow = {
  id: string;
  type: 'direct' | 'group';
  name: string | null;
  created_by: string | null;
  created_at: Date;
  last_seq: number;
};

export type MemberRow = {
  user: PublicUser;
  role: 'admin' | 'member';
  last_read_seq: number;
  joined_at: Date;
};

export type ConversationSummary = ConversationRow & {
  members: MemberRow[];
  last_message: {
    id: string;
    conversation_id: string;
    seq: number;
    sender_id: string;
    client_msg_id: string;
    type: 'text' | 'image' | 'file';
    content: string;
    created_at: Date;
  } | null;
  last_read_seq: number;
  unread_count: number;
};

type MessageJoinRow = {
  id: string;
  conversation_id: string;
  seq: string;
  sender_id: string;
  client_msg_id: string;
  type: 'text' | 'image' | 'file';
  content: string;
  created_at: Date;
};

const MESSAGE_COLUMNS = `id, conversation_id, seq, sender_id, client_msg_id, type, content, created_at`;

function mapMessage(row: MessageJoinRow) {
  return { ...row, seq: Number(row.seq) };
}

export class ConversationRepository {
  constructor(private readonly db: Db) {}

  async isMember(conversationId: string, userId: string): Promise<boolean> {
    const { rows } = await this.db.query(
      `SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, userId],
    );
    return rows.length > 0;
  }

  async exists(conversationId: string): Promise<boolean> {
    const { rows } = await this.db.query(`SELECT 1 FROM conversations WHERE id = $1`, [
      conversationId,
    ]);
    return rows.length > 0;
  }

  async memberIds(conversationId: string): Promise<string[]> {
    const { rows } = await this.db.query<{ user_id: string }>(
      `SELECT user_id FROM conversation_members WHERE conversation_id = $1`,
      [conversationId],
    );
    return rows.map((row) => row.user_id);
  }

  async getRow(conversationId: string): Promise<ConversationRow | null> {
    const { rows } = await this.db.query<ConversationRow & { last_seq: string }>(
      `SELECT id, type, name, created_by, created_at, last_seq
         FROM conversations WHERE id = $1`,
      [conversationId],
    );
    const row = rows[0];
    return row ? { ...row, last_seq: Number(row.last_seq) } : null;
  }

  async findDirectId(userA: string, userB: string): Promise<string | null> {
    const { rows } = await this.db.query<{ id: string }>(
      `SELECT id FROM conversations WHERE direct_key = $1`,
      [directKey(userA, userB)],
    );
    return rows[0]?.id ?? null;
  }

  /**
   * Idempotent 1:1 conversation creation. The canonical `direct_key` plus a
   * unique index means two simultaneous creators converge on one row.
   */
  async findOrCreateDirect(currentUserId: string, otherUserId: string): Promise<ConversationRow> {
    if (currentUserId === otherUserId) {
      throw new ApiError('validation_error', 'A direct conversation needs another member');
    }

    const client = await this.db.connect();
    try {
      await client.query('BEGIN');
      const key = directKey(currentUserId, otherUserId);

      const insert = await client.query<ConversationRow & { last_seq: string }>(
        `INSERT INTO conversations (type, created_by, direct_key)
         VALUES ('direct', $1, $2)
         ON CONFLICT (direct_key) WHERE direct_key IS NOT NULL DO NOTHING
         RETURNING id, type, name, created_by, created_at, last_seq`,
        [currentUserId, key],
      );

      let conversation = insert.rows[0];
      if (!conversation) {
        const existing = await client.query<ConversationRow & { last_seq: string }>(
          `SELECT id, type, name, created_by, created_at, last_seq
             FROM conversations WHERE direct_key = $1`,
          [key],
        );
        conversation = existing.rows[0]!;
      } else {
        await client.query(
          `INSERT INTO conversation_members (conversation_id, user_id, role)
           VALUES ($1, $2, 'member'), ($1, $3, 'member')`,
          [conversation.id, currentUserId, otherUserId],
        );
      }

      await client.query('COMMIT');
      return { ...conversation, last_seq: Number(conversation.last_seq) };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  /** Returns the conversation the caller may access, or throws. */
  async requireMemberConversation(conversationId: string, userId: string): Promise<ConversationRow> {
    const conversation = await this.getRow(conversationId);
    if (!conversation) {
      throw new ApiError('conversation_not_found', 'Conversation not found');
    }
    if (!(await this.isMember(conversationId, userId))) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
    return conversation;
  }

  async list(userId: string, limit: number, before?: string): Promise<{
    conversations: ConversationSummary[];
    nextCursor: string | null;
  }> {
    const params: unknown[] = [userId];
    let cursorClause = '';

    if (before) {
      params.push(before);
      cursorClause = `
        AND (
          COALESCE(activity.last_message_at, c.created_at), c.id
        ) < (
          SELECT COALESCE(cursor_activity.last_message_at, cur.created_at), cur.id
            FROM conversations cur
            LEFT JOIN LATERAL (
              SELECT created_at AS last_message_at FROM messages
               WHERE conversation_id = cur.id ORDER BY seq DESC LIMIT 1
            ) cursor_activity ON true
           WHERE cur.id = $2
        )`;
    }

    params.push(limit + 1);
    const { rows } = await this.db.query<
      ConversationRow & {
        last_read_seq: string;
        unread_count: string;
        activity_at: Date;
        lm_id: string | null;
        lm_seq: string | null;
        lm_sender_id: string | null;
        lm_client_msg_id: string | null;
        lm_type: 'text' | 'image' | 'file' | null;
        lm_content: string | null;
        lm_created_at: Date | null;
      }
    >(
      `SELECT c.id, c.type, c.name, c.created_by, c.created_at, c.last_seq,
              cm.last_read_seq,
              COALESCE(activity.last_message_at, c.created_at) AS activity_at,
              (SELECT count(*) FROM messages m
                WHERE m.conversation_id = c.id
                  AND m.seq > cm.last_read_seq
                  AND m.sender_id <> $1)::text AS unread_count,
              lm.id AS lm_id, lm.seq AS lm_seq, lm.sender_id AS lm_sender_id,
              lm.client_msg_id AS lm_client_msg_id, lm.type AS lm_type,
              lm.content AS lm_content, lm.created_at AS lm_created_at
         FROM conversations c
         JOIN conversation_members cm
           ON cm.conversation_id = c.id AND cm.user_id = $1
         LEFT JOIN LATERAL (
           SELECT created_at AS last_message_at FROM messages
            WHERE conversation_id = c.id ORDER BY seq DESC LIMIT 1
         ) activity ON true
         LEFT JOIN LATERAL (
           SELECT ${MESSAGE_COLUMNS} FROM messages
            WHERE conversation_id = c.id ORDER BY seq DESC LIMIT 1
         ) lm ON true
        WHERE true ${cursorClause}
        ORDER BY activity_at DESC, c.id DESC
        LIMIT $${params.length}`,
      params,
    );

    const page = rows.slice(0, limit);
    const withMembers = await this.attachMembers(
      page.map((row) => ({
        id: row.id,
        type: row.type,
        name: row.name,
        created_by: row.created_by,
        created_at: row.created_at,
        last_seq: Number(row.last_seq),
        last_read_seq: Number(row.last_read_seq),
        unread_count: Number(row.unread_count),
        last_message: row.lm_id
          ? {
              id: row.lm_id,
              conversation_id: row.id,
              seq: Number(row.lm_seq),
              sender_id: row.lm_sender_id!,
              client_msg_id: row.lm_client_msg_id!,
              type: row.lm_type!,
              content: row.lm_content!,
              created_at: row.lm_created_at!,
            }
          : null,
      })),
    );

    return {
      conversations: withMembers,
      nextCursor: rows.length > limit ? page[page.length - 1]!.id : null,
    };
  }

  async getSummary(conversationId: string, userId: string): Promise<ConversationSummary> {
    const conversation = await this.requireMemberConversation(conversationId, userId);
    const { rows } = await this.db.query<{ last_read_seq: string; unread_count: string }>(
      `SELECT cm.last_read_seq,
              (SELECT count(*) FROM messages m
                WHERE m.conversation_id = cm.conversation_id
                  AND m.seq > cm.last_read_seq
                  AND m.sender_id <> $2)::text AS unread_count
         FROM conversation_members cm
        WHERE cm.conversation_id = $1 AND cm.user_id = $2`,
      [conversationId, userId],
    );
    const { rows: lastRows } = await this.db.query<MessageJoinRow>(
      `SELECT ${MESSAGE_COLUMNS} FROM messages
        WHERE conversation_id = $1 ORDER BY seq DESC LIMIT 1`,
      [conversationId],
    );

    const [summary] = await this.attachMembers([
      {
        ...conversation,
        last_read_seq: Number(rows[0]?.last_read_seq ?? 0),
        unread_count: Number(rows[0]?.unread_count ?? 0),
        last_message: lastRows[0] ? mapMessage(lastRows[0]) : null,
      },
    ]);
    return summary!;
  }

  private async attachMembers(
    conversations: Omit<ConversationSummary, 'members'>[],
  ): Promise<ConversationSummary[]> {
    if (conversations.length === 0) return [];

    const { rows } = await this.db.query<
      UserRow & {
        conversation_id: string;
        role: 'admin' | 'member';
        last_read_seq: string;
        joined_at: Date;
      }
    >(
      `SELECT cm.conversation_id, cm.role, cm.last_read_seq, cm.joined_at,
              u.id, u.phone_or_email, u.name, u.avatar_url, u.created_at
         FROM conversation_members cm
         JOIN users u ON u.id = cm.user_id
        WHERE cm.conversation_id = ANY($1::uuid[])
        ORDER BY cm.joined_at ASC`,
      [conversations.map((conversation) => conversation.id)],
    );

    const byConversation = new Map<string, MemberRow[]>();
    for (const row of rows) {
      const members = byConversation.get(row.conversation_id) ?? [];
      members.push({
        user: toPublicUser({
          id: row.id,
          phone_or_email: row.phone_or_email,
          name: row.name,
          avatar_url: row.avatar_url,
          created_at: row.created_at,
        }),
        role: row.role,
        last_read_seq: Number(row.last_read_seq),
        joined_at: row.joined_at,
      });
      byConversation.set(row.conversation_id, members);
    }

    return conversations.map((conversation) => ({
      ...conversation,
      members: byConversation.get(conversation.id) ?? [],
    }));
  }
}

export type { PoolClient };
