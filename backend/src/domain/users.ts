import type { Db } from '../lib/db.js';

export type UserRow = {
  id: string;
  phone_or_email: string;
  name: string;
  avatar_url: string | null;
  created_at: Date;
};

export type PublicUser = {
  id: string;
  name: string;
  avatar_url: string | null;
  created_at: Date;
  phone_or_email?: string;
};

export function toPublicUser(row: UserRow, includeContact = false): PublicUser {
  return {
    id: row.id,
    name: row.name,
    avatar_url: row.avatar_url,
    created_at: row.created_at,
    ...(includeContact ? { phone_or_email: row.phone_or_email } : {}),
  };
}

export class UserRepository {
  constructor(private readonly db: Db) {}

  async findByContact(phoneOrEmail: string): Promise<(UserRow & { password_hash: string }) | null> {
    const { rows } = await this.db.query<UserRow & { password_hash: string }>(
      `SELECT id, phone_or_email, name, avatar_url, created_at, password_hash
         FROM users
        WHERE lower(phone_or_email) = lower($1)`,
      [phoneOrEmail],
    );
    return rows[0] ?? null;
  }

  async findById(id: string): Promise<UserRow | null> {
    const { rows } = await this.db.query<UserRow>(
      `SELECT id, phone_or_email, name, avatar_url, created_at FROM users WHERE id = $1`,
      [id],
    );
    return rows[0] ?? null;
  }

  async create(input: {
    phoneOrEmail: string;
    name: string;
    passwordHash: string;
  }): Promise<UserRow> {
    const { rows } = await this.db.query<UserRow>(
      `INSERT INTO users (phone_or_email, name, password_hash)
       VALUES ($1, $2, $3)
       RETURNING id, phone_or_email, name, avatar_url, created_at`,
      [input.phoneOrEmail, input.name, input.passwordHash],
    );
    return rows[0]!;
  }

  /** True when both users belong to at least one conversation together. */
  async sharesConversationWith(userA: string, userB: string): Promise<boolean> {
    const { rows } = await this.db.query(
      `SELECT 1
         FROM conversation_members a
         JOIN conversation_members b
           ON b.conversation_id = a.conversation_id AND b.user_id = $2
        WHERE a.user_id = $1
        LIMIT 1`,
      [userA, userB],
    );
    return rows.length > 0;
  }

  /** Ids from `ids` that correspond to an existing user. */
  async existingIds(ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set();
    const { rows } = await this.db.query<{ id: string }>(
      `SELECT id FROM users WHERE id = ANY($1::uuid[])`,
      [ids],
    );
    return new Set(rows.map((row) => row.id));
  }
}
