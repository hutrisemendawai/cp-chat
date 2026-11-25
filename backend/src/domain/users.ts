import type { Db } from '../lib/db.js';

export type UserStatus = 'online' | 'idle' | 'dnd' | 'invisible';
export type EffectiveStatus = 'online' | 'idle' | 'dnd' | 'offline';

export const USER_STATUSES: readonly UserStatus[] = ['online', 'idle', 'dnd', 'invisible'];

export type UserRow = {
  id: string;
  username: string;
  phone_or_email: string;
  name: string;
  nickname: string | null;
  avatar_url: string | null;
  status: UserStatus;
  custom_status: string | null;
  bio: string | null;
  last_seen_at: Date | null;
  created_at: Date;
};

export type PublicUser = {
  id: string;
  username: string;
  name: string;
  nickname: string | null;
  avatar_url: string | null;
  custom_status: string | null;
  bio: string | null;
  /**
   * The caller's own profile carries the real preference (including
   * `invisible`); another user's carries the masked, visible value.
   */
  status: UserStatus | EffectiveStatus;
  effective_status: EffectiveStatus;
  created_at: Date;
  phone_or_email?: string;
};

const USER_COLUMNS = `id, username, phone_or_email, name, nickname, avatar_url, status,
                      custom_status, bio, last_seen_at, created_at`;

/**
 * Visibility rule for another user's presence preference.
 *
 * A user set to `invisible` appears `offline` to everyone else, whatever the
 * Redis presence key says. Everyone else shows their preferred state. `online`
 * here means "visible and connected", so a masked user reports `online: false`.
 */
export function visibleStatus(preference: UserStatus): EffectiveStatus {
  return preference === 'invisible' ? 'offline' : preference;
}

/** Own-profile view: the real preference plus what peers currently see. */
export function toOwnUser(row: UserRow, connected: boolean): PublicUser {
  const effective: EffectiveStatus =
    row.status === 'invisible' ? 'offline' : connected ? row.status : 'offline';
  return {
    id: row.id,
    username: row.username,
    name: row.name,
    nickname: row.nickname,
    avatar_url: row.avatar_url,
    custom_status: row.custom_status,
    bio: row.bio,
    status: row.status,
    effective_status: effective,
    created_at: row.created_at,
    phone_or_email: row.phone_or_email,
  };
}

/**
 * Public projection. `invisible` never leaves the server; it is reported as
 * `offline` so another user cannot infer the privacy setting. `connected` comes
 * from the Redis presence key and only matters for non-invisible users.
 */
export function toPublicUser(
  row: UserRow,
  includeContact = false,
  connected = false,
): PublicUser {
  const effective = row.status === 'invisible' ? 'offline' : connected ? row.status : 'offline';
  return {
    id: row.id,
    username: row.username,
    name: row.name,
    nickname: row.nickname,
    avatar_url: row.avatar_url,
    custom_status: row.custom_status,
    bio: row.bio,
    status: visibleStatus(row.status),
    effective_status: effective,
    created_at: row.created_at,
    ...(includeContact ? { phone_or_email: row.phone_or_email } : {}),
  };
}

export type ProfilePatch = {
  name?: string;
  nickname?: string | null;
  avatar_url?: string | null;
  status?: UserStatus;
  custom_status?: string | null;
  bio?: string | null;
};

export class UserRepository {
  constructor(private readonly db: Db) {}

  async findByContact(phoneOrEmail: string): Promise<(UserRow & { password_hash: string }) | null> {
    const { rows } = await this.db.query<UserRow & { password_hash: string }>(
      `SELECT ${USER_COLUMNS}, password_hash
         FROM users
        WHERE lower(phone_or_email) = lower($1)`,
      [phoneOrEmail],
    );
    return rows[0] ?? null;
  }

  async findByUsername(username: string): Promise<UserRow | null> {
    const { rows } = await this.db.query<UserRow>(
      `SELECT ${USER_COLUMNS} FROM users WHERE lower(username) = lower($1)`,
      [username],
    );
    return rows[0] ?? null;
  }

  /**
   * Resolves a login identifier that may be either an email/phone or a
   * username. Contact matches are preferred so an address that happens to also
   * be a username still resolves to its own account.
   */
  async findByIdentifier(
    identifier: string,
  ): Promise<(UserRow & { password_hash: string }) | null> {
    const { rows } = await this.db.query<UserRow & { password_hash: string }>(
      `SELECT ${USER_COLUMNS}, password_hash
         FROM users
        WHERE lower(phone_or_email) = lower($1) OR lower(username) = lower($1)
        ORDER BY CASE WHEN lower(phone_or_email) = lower($1) THEN 0 ELSE 1 END, id ASC
        LIMIT 1`,
      [identifier],
    );
    return rows[0] ?? null;
  }

  async findById(id: string): Promise<UserRow | null> {
    const { rows } = await this.db.query<UserRow>(
      `SELECT ${USER_COLUMNS} FROM users WHERE id = $1`,
      [id],
    );
    return rows[0] ?? null;
  }

  async create(input: {
    username: string;
    phoneOrEmail: string;
    name: string;
    passwordHash: string;
  }): Promise<UserRow> {
    const { rows } = await this.db.query<UserRow>(
      `INSERT INTO users (username, phone_or_email, name, password_hash)
       VALUES ($1, $2, $3, $4)
       RETURNING ${USER_COLUMNS}`,
      [input.username, input.phoneOrEmail, input.name, input.passwordHash],
    );
    return rows[0]!;
  }

  /**
   * Applies a partial profile update.
   *
   * A field is only written when it is present in the patch, so omitting
   * `nickname` leaves it alone while `nickname: null` clears it. An empty
   * nickname is normalized to NULL: the display helper falls back to `name`
   * and an empty string would otherwise render "Name ()".
   */
  async updateProfile(userId: string, patch: ProfilePatch): Promise<UserRow | null> {
    const assignments: string[] = [];
    const params: unknown[] = [userId];

    const add = (column: string, value: unknown) => {
      params.push(value);
      assignments.push(`${column} = $${params.length}`);
    };

    if (patch.name !== undefined) add('name', patch.name);
    if (patch.nickname !== undefined) {
      const trimmed = patch.nickname?.trim();
      add('nickname', trimmed ? trimmed : null);
    }
    if (patch.avatar_url !== undefined) add('avatar_url', patch.avatar_url);
    if (patch.status !== undefined) add('status', patch.status);
    if (patch.custom_status !== undefined) {
      const trimmed = patch.custom_status?.trim();
      add('custom_status', trimmed ? trimmed : null);
    }
    if (patch.bio !== undefined) {
      const trimmed = patch.bio?.trim();
      add('bio', trimmed ? trimmed : null);
    }

    if (assignments.length === 0) return this.findById(userId);

    const { rows } = await this.db.query<UserRow>(
      `UPDATE users SET ${assignments.join(', ')}
        WHERE id = $1
        RETURNING ${USER_COLUMNS}`,
      params,
    );
    return rows[0] ?? null;
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

  /**
   * True when the object key is referenced as a user's avatar (and is therefore
   * readable by anyone authenticated, so a profile photo loads before a chat
   * exists) or as the avatar of a conversation the caller belongs to.
   */
  async isAvatarVisibleTo(objectKey: string, viewerId: string): Promise<boolean> {
    const { rows } = await this.db.query(
      `SELECT 1 FROM users WHERE avatar_url = $1
       UNION ALL
       SELECT 1 FROM conversations c
         JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = $2
        WHERE c.avatar_url = $1
       LIMIT 1`,
      [objectKey, viewerId],
    );
    return rows.length > 0;
  }
}
