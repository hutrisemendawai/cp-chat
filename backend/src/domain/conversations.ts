import { ApiError } from '../lib/errors.js';
import type { Db, PoolClient } from '../lib/db.js';
import { directKey } from '../lib/ids.js';
import { toPublicUser, type PublicUser, type UserRow } from './users.js';

export type ConversationRow = {
  id: string;
  type: 'direct' | 'group';
  name: string | null;
  avatar_url: string | null;
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
  cleared_seq: number;
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

const CONVERSATION_COLUMNS = `id, type, name, avatar_url, created_by, created_at, last_seq`;

function mapMessage(row: MessageJoinRow) {
  return { ...row, seq: Number(row.seq) };
}

function mapConversation(row: ConversationRow & { last_seq: string | number }): ConversationRow {
  return { ...row, last_seq: Number(row.last_seq) };
}

export class ConversationRepository {
  constructor(
    private readonly db: Db,
    /**
     * Optional presence lookup so a projected member list carries an accurate
     * `effective_status`. Without it (e.g. a unit test constructing the repo
     * directly) members report `offline`.
     */
    private readonly presence?: { onlineUserIds(ids: string[]): Promise<Set<string>> },
  ) {}

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
      `SELECT ${CONVERSATION_COLUMNS} FROM conversations WHERE id = $1`,
      [conversationId],
    );
    const row = rows[0];
    return row ? mapConversation(row) : null;
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
    const { conversation } = await this.findOrCreateDirectWithStatus(
      currentUserId,
      otherUserId,
    );
    return conversation;
  }

  /**
   * Same as {@link findOrCreateDirect}, but also reports whether this call
   * created the conversation. Callers use `created` to announce a brand new
   * direct chat to both members exactly once instead of on every re-open.
   */
  async findOrCreateDirectWithStatus(
    currentUserId: string,
    otherUserId: string,
  ): Promise<{ conversation: ConversationRow; created: boolean }> {
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
         RETURNING ${CONVERSATION_COLUMNS}`,
        [currentUserId, key],
      );

      let conversation = insert.rows[0];
      const created = conversation !== undefined;
      if (!conversation) {
        const existing = await client.query<ConversationRow & { last_seq: string }>(
          `SELECT ${CONVERSATION_COLUMNS} FROM conversations WHERE direct_key = $1`,
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
      return { conversation: mapConversation(conversation), created };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  /** Creates a group; the creator is the first admin. */
  async createGroup(input: {
    creatorId: string;
    name: string;
    memberIds: string[];
    avatarUrl?: string | null;
    maxMembers: number;
  }): Promise<ConversationRow> {
    const others = [...new Set(input.memberIds)].filter((id) => id !== input.creatorId);
    if (others.length === 0) {
      throw new ApiError('validation_error', 'A group needs at least one other member');
    }
    if (1 + others.length > input.maxMembers) {
      throw new ApiError(
        'group_full',
        `Groups are limited to ${input.maxMembers} members`,
      );
    }

    return this.transaction(async (client) => {
      const created = await client.query<ConversationRow & { last_seq: string }>(
        `INSERT INTO conversations (type, name, avatar_url, created_by)
         VALUES ('group', $1, $2, $3)
         RETURNING ${CONVERSATION_COLUMNS}`,
        [input.name, input.avatarUrl ?? null, input.creatorId],
      );
      const conversation = created.rows[0]!;

      const ids = [input.creatorId, ...others];
      await client.query(
        `INSERT INTO conversation_members (conversation_id, user_id, role)
         SELECT $1, member_id, CASE WHEN member_id = $2 THEN 'admin' ELSE 'member' END
           FROM unnest($3::uuid[]) AS member_id`,
        [conversation.id, input.creatorId, ids],
      );

      return mapConversation(conversation);
    });
  }

  /** Updates a group's mutable metadata. Caller must already be an admin. */
  async updateGroup(
    conversationId: string,
    patch: { name?: string; avatarUrl?: string | null },
  ): Promise<ConversationRow> {
    const { rows } = await this.db.query<ConversationRow & { last_seq: string }>(
      `UPDATE conversations
          SET name = COALESCE($2, name),
              avatar_url = CASE WHEN $3 THEN $4 ELSE avatar_url END
        WHERE id = $1 AND type = 'group'
        RETURNING ${CONVERSATION_COLUMNS}`,
      [conversationId, patch.name ?? null, patch.avatarUrl !== undefined, patch.avatarUrl ?? null],
    );
    if (!rows[0]) {
      throw new ApiError('conversation_not_found', 'Group not found');
    }
    return mapConversation(rows[0]);
  }

  /**
   * Adds members to a group. The conversation row is locked so two concurrent
   * additions cannot both pass the member-limit check.
   */
  async addMembers(input: {
    conversationId: string;
    actorId: string;
    userIds: string[];
    maxMembers: number;
  }): Promise<string[]> {
    return this.transaction(async (client) => {
      await this.lockConversation(client, input.conversationId, 'group');
      await this.requireAdminIn(client, input.conversationId, input.actorId);

      const current = await client.query<{ user_id: string }>(
        `SELECT user_id FROM conversation_members WHERE conversation_id = $1`,
        [input.conversationId],
      );
      const existing = new Set(current.rows.map((row) => row.user_id));
      const toAdd = [...new Set(input.userIds)].filter((id) => !existing.has(id));

      if (existing.size + toAdd.length > input.maxMembers) {
        throw new ApiError(
          'group_full',
          `Groups are limited to ${input.maxMembers} members`,
        );
      }

      if (toAdd.length > 0) {
        await client.query(
          `INSERT INTO conversation_members (conversation_id, user_id, role)
           SELECT $1, member_id, 'member'
             FROM unnest($2::uuid[]) AS member_id
           ON CONFLICT (conversation_id, user_id) DO NOTHING`,
          [input.conversationId, toAdd],
        );
      }
      return toAdd;
    });
  }

  /**
   * Removes a member. Members may remove themselves (leave); removing anyone
   * else requires admin. The last admin cannot leave a group that still has
   * other members, so the group always has someone who can manage it.
   */
  async removeMember(input: {
    conversationId: string;
    actorId: string;
    targetId: string;
  }): Promise<{ conversationDeleted: boolean }> {
    return this.transaction(async (client) => {
      await this.lockConversation(client, input.conversationId, 'group');

      if (input.actorId !== input.targetId) {
        await this.requireAdminIn(client, input.conversationId, input.actorId);
      }

      const members = await client.query<{ user_id: string; role: 'admin' | 'member' }>(
        `SELECT user_id, role FROM conversation_members WHERE conversation_id = $1`,
        [input.conversationId],
      );
      const target = members.rows.find((row) => row.user_id === input.targetId);
      if (!target) {
        throw new ApiError('not_found', 'Member not found');
      }

      const remainingAdmins = members.rows.filter(
        (row) => row.role === 'admin' && row.user_id !== input.targetId,
      );
      if (target.role === 'admin' && remainingAdmins.length === 0 && members.rows.length > 1) {
        throw new ApiError(
          'last_admin',
          'Promote another member to admin before leaving',
        );
      }

      await client.query(
        `DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
        [input.conversationId, input.targetId],
      );

      if (members.rows.length === 1) {
        await client.query(`DELETE FROM conversations WHERE id = $1`, [input.conversationId]);
        return { conversationDeleted: true };
      }
      return { conversationDeleted: false };
    });
  }

  async requireAdmin(conversationId: string, userId: string): Promise<void> {
    await this.requireAdminIn(this.db, conversationId, userId);
  }

  async requireGroup(conversationId: string): Promise<ConversationRow> {
    const conversation = await this.getRow(conversationId);
    if (!conversation) {
      throw new ApiError('conversation_not_found', 'Conversation not found');
    }
    if (conversation.type !== 'group') {
      throw new ApiError('unsupported_conversation_type', 'This action requires a group');
    }
    return conversation;
  }

  /**
   * Read tally for an aggregated-read group UI: how many members other than the
   * sender have read up to and including `seq`.
   */
  async readStats(
    conversationId: string,
    seq: number,
    senderId: string,
  ): Promise<{ readCount: number; memberCount: number }> {
    const { rows } = await this.db.query<{ read_count: string; member_count: string }>(
      `SELECT count(*) FILTER (WHERE user_id <> $2 AND last_read_seq >= $3)::text AS read_count,
              count(*) FILTER (WHERE user_id <> $2)::text AS member_count
         FROM conversation_members
        WHERE conversation_id = $1`,
      [conversationId, senderId, seq],
    );
    return {
      readCount: Number(rows[0]?.read_count ?? 0),
      memberCount: Number(rows[0]?.member_count ?? 0),
    };
  }

  /** Returns the conversation the caller may access plus their cleared watermark, or throws. */
  async requireMemberConversation(
    conversationId: string,
    userId: string,
  ): Promise<ConversationRow & { cleared_seq: number }> {
    const conversation = await this.getRow(conversationId);
    if (!conversation) {
      throw new ApiError('conversation_not_found', 'Conversation not found');
    }
    const { rows } = await this.db.query<{ cleared_seq: string }>(
      `SELECT cleared_seq FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, userId],
    );
    if (!rows[0]) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
    return { ...conversation, cleared_seq: Number(rows[0].cleared_seq) };
  }

  /**
   * Advances this member's per-conversation history watermark to `last_seq` so
   * cleared messages are no longer served on sync, pagination, search, or list
   * previews. Monotonic and idempotent; other members are unaffected.
   */
  async clearHistory(
    conversationId: string,
    userId: string,
  ): Promise<{ clearedSeq: number }> {
    await this.requireMemberConversation(conversationId, userId);
    const { rows } = await this.db.query<{ cleared_seq: string }>(
      `UPDATE conversation_members cm
          SET cleared_seq = GREATEST(cm.cleared_seq, c.last_seq),
              last_read_seq = GREATEST(cm.last_read_seq, c.last_seq)
         FROM conversations c
        WHERE cm.conversation_id = c.id
          AND cm.conversation_id = $1
          AND cm.user_id = $2
       RETURNING cm.cleared_seq`,
      [conversationId, userId],
    );
    if (!rows[0]) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
    return { clearedSeq: Number(rows[0].cleared_seq) };
  }

  /**
   * Advances the history watermark across every conversation (direct and group)
   * that `userId` belongs to. Monotonic and idempotent.
   */
  async clearAllHistory(userId: string): Promise<{
    conversations: { conversationId: string; clearedSeq: number }[];
    clearedAt: Date;
  }> {
    const { rows } = await this.db.query<{ conversation_id: string; cleared_seq: string }>(
      `UPDATE conversation_members cm
          SET cleared_seq = GREATEST(cm.cleared_seq, c.last_seq),
              last_read_seq = GREATEST(cm.last_read_seq, c.last_seq)
         FROM conversations c
        WHERE cm.conversation_id = c.id
          AND cm.user_id = $1
       RETURNING cm.conversation_id, cm.cleared_seq`,
      [userId],
    );
    return {
      conversations: rows.map((row) => ({
        conversationId: row.conversation_id,
        clearedSeq: Number(row.cleared_seq),
      })),
      clearedAt: new Date(),
    };
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
            JOIN conversation_members cm_cur
              ON cm_cur.conversation_id = cur.id AND cm_cur.user_id = $1
            LEFT JOIN LATERAL (
              SELECT created_at AS last_message_at FROM messages
               WHERE conversation_id = cur.id
                 AND seq > cm_cur.cleared_seq
               ORDER BY seq DESC LIMIT 1
            ) cursor_activity ON true
           WHERE cur.id = $2
        )`;
    }

    params.push(limit + 1);
    const { rows } = await this.db.query<
      ConversationRow & {
        last_read_seq: string;
        cleared_seq: string;
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
      `SELECT c.id, c.type, c.name, c.avatar_url, c.created_by, c.created_at, c.last_seq,
              cm.last_read_seq,
              cm.cleared_seq,
              COALESCE(activity.last_message_at, c.created_at) AS activity_at,
              (SELECT count(*) FROM messages m
                WHERE m.conversation_id = c.id
                  AND m.seq > GREATEST(cm.last_read_seq, cm.cleared_seq)
                  AND m.sender_id <> $1)::text AS unread_count,
              lm.id AS lm_id, lm.seq AS lm_seq, lm.sender_id AS lm_sender_id,
              lm.client_msg_id AS lm_client_msg_id, lm.type AS lm_type,
              lm.content AS lm_content, lm.created_at AS lm_created_at
         FROM conversations c
         JOIN conversation_members cm
           ON cm.conversation_id = c.id AND cm.user_id = $1
         LEFT JOIN LATERAL (
           SELECT created_at AS last_message_at FROM messages
            WHERE conversation_id = c.id
              AND seq > cm.cleared_seq
            ORDER BY seq DESC LIMIT 1
         ) activity ON true
         LEFT JOIN LATERAL (
           SELECT ${MESSAGE_COLUMNS} FROM messages
            WHERE conversation_id = c.id
              AND seq > cm.cleared_seq
            ORDER BY seq DESC LIMIT 1
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
        avatar_url: row.avatar_url,
        created_by: row.created_by,
        created_at: row.created_at,
        last_seq: Number(row.last_seq),
        last_read_seq: Number(row.last_read_seq),
        cleared_seq: Number(row.cleared_seq),
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
    const { rows } = await this.db.query<{
      last_read_seq: string;
      cleared_seq: string;
      unread_count: string;
    }>(
      `SELECT cm.last_read_seq,
              cm.cleared_seq,
              (SELECT count(*) FROM messages m
                WHERE m.conversation_id = cm.conversation_id
                  AND m.seq > GREATEST(cm.last_read_seq, cm.cleared_seq)
                  AND m.sender_id <> $2)::text AS unread_count
         FROM conversation_members cm
        WHERE cm.conversation_id = $1 AND cm.user_id = $2`,
      [conversationId, userId],
    );
    const clearedSeq = Number(rows[0]?.cleared_seq ?? conversation.cleared_seq);
    const { rows: lastRows } = await this.db.query<MessageJoinRow>(
      `SELECT ${MESSAGE_COLUMNS} FROM messages
        WHERE conversation_id = $1 AND seq > $2 ORDER BY seq DESC LIMIT 1`,
      [conversationId, clearedSeq],
    );

    const [summary] = await this.attachMembers([
      {
        ...conversation,
        last_read_seq: Number(rows[0]?.last_read_seq ?? 0),
        cleared_seq: clearedSeq,
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
              u.id, u.username, u.phone_or_email, u.name, u.nickname, u.avatar_url,
              u.status, u.custom_status, u.bio, u.last_seen_at, u.created_at
         FROM conversation_members cm
         JOIN users u ON u.id = cm.user_id
        WHERE cm.conversation_id = ANY($1::uuid[])
        ORDER BY cm.joined_at ASC`,
      [conversations.map((conversation) => conversation.id)],
    );

    const online = this.presence
      ? await this.presence.onlineUserIds([...new Set(rows.map((row) => row.id))])
      : new Set<string>();

    const byConversation = new Map<string, MemberRow[]>();
    for (const row of rows) {
      const members = byConversation.get(row.conversation_id) ?? [];
      members.push({
        user: toPublicUser(
          {
            id: row.id,
            username: row.username,
            phone_or_email: row.phone_or_email,
            name: row.name,
            nickname: row.nickname,
            avatar_url: row.avatar_url,
            status: row.status,
            custom_status: row.custom_status,
            bio: row.bio,
            last_seen_at: row.last_seen_at,
            created_at: row.created_at,
          },
          true,
          online.has(row.id),
        ),
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

  private async lockConversation(
    client: Pick<Db, 'query'>,
    conversationId: string,
    expectedType: 'group',
  ): Promise<void> {
    const { rows } = await client.query<{ type: 'direct' | 'group' }>(
      `SELECT type FROM conversations WHERE id = $1 FOR UPDATE`,
      [conversationId],
    );
    if (!rows[0]) {
      throw new ApiError('conversation_not_found', 'Conversation not found');
    }
    if (rows[0].type !== expectedType) {
      throw new ApiError('unsupported_conversation_type', 'This action requires a group');
    }
  }

  private async requireAdminIn(
    client: Pick<Db, 'query'>,
    conversationId: string,
    userId: string,
  ): Promise<void> {
    const { rows } = await client.query<{ role: 'admin' | 'member' }>(
      `SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, userId],
    );
    if (!rows[0]) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
    if (rows[0].role !== 'admin') {
      throw new ApiError('not_an_admin', 'Only group admins can do that');
    }
  }

  private async transaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.db.connect();
    try {
      await client.query('BEGIN');
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}

export type { PoolClient };
