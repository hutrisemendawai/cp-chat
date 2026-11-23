import type { Db } from '../lib/db.js';
import { effectiveStatus, type PresenceService } from './presence.js';
import type { UserRow } from './users.js';

export type FriendUser = {
  id: string;
  name: string;
  nickname: string | null;
  phone_or_email: string;
  avatar_url: string | null;
  custom_status: string | null;
  effective_status: ReturnType<typeof effectiveStatus>;
  online: boolean;
  last_seen_at: Date | null;
  is_friend: boolean;
};

type FriendRow = UserRow & { is_friend: boolean };

const USER_COLUMNS = `u.id, u.phone_or_email, u.name, u.nickname, u.avatar_url,
                      u.status, u.custom_status, u.bio, u.last_seen_at, u.created_at`;

/**
 * Projects a user row for the directory/friends lists.
 *
 * `online` means "visible and connected", so an `invisible` user reports
 * `false` even with a live Redis key. The raw preference is never returned.
 */
export function toFriendUser(row: FriendRow, connected: boolean): FriendUser {
  const status = effectiveStatus(row.status, connected);
  return {
    id: row.id,
    name: row.name,
    nickname: row.nickname,
    phone_or_email: row.phone_or_email,
    avatar_url: row.avatar_url,
    custom_status: row.custom_status,
    effective_status: status,
    online: status !== 'offline',
    last_seen_at: row.last_seen_at,
    is_friend: row.is_friend,
  };
}

/**
 * Friends/contacts storage plus the directory search that backs the mobile
 * user pickers. Search runs over `name` and `phone_or_email` (never the UUID)
 * and is always scoped to "not me".
 */
export class FriendRepository {
  constructor(
    private readonly db: Db,
    private readonly presence: Pick<PresenceService, 'onlineUserIds'>,
  ) {}

  /**
   * Case-insensitive substring search over name and contact. Exact email/name
   * and prefix matches sort first, then alphabetical by name, so typing a full
   * address surfaces that person at the top.
   */
  async search(callerId: string, query: string, limit: number): Promise<FriendUser[]> {
    const { rows } = await this.db.query<FriendRow>(
      `SELECT ${USER_COLUMNS},
              EXISTS (
                SELECT 1 FROM user_friends f
                 WHERE f.user_id = $1 AND f.friend_id = u.id
              ) AS is_friend
         FROM users u
        WHERE u.id <> $1
          AND (lower(u.name) LIKE '%' || lower($2) || '%'
               OR lower(u.phone_or_email) LIKE '%' || lower($2) || '%')
        ORDER BY
          CASE
            WHEN lower(u.phone_or_email) = lower($2) THEN 0
            WHEN lower(u.phone_or_email) LIKE lower($2) || '%' THEN 1
            WHEN lower(u.name) = lower($2) THEN 2
            WHEN lower(u.name) LIKE lower($2) || '%' THEN 3
            ELSE 4
          END,
          lower(u.name) ASC,
          u.id ASC
        LIMIT $3`,
      [callerId, query, limit],
    );
    return this.project(rows);
  }

  /** The caller's friends. Ordering (online first, then name) happens in JS. */
  async list(userId: string): Promise<FriendUser[]> {
    const { rows } = await this.db.query<FriendRow>(
      `SELECT ${USER_COLUMNS}, TRUE AS is_friend
         FROM user_friends f
         JOIN users u ON u.id = f.friend_id
        WHERE f.user_id = $1`,
      [userId],
    );
    const projected = await this.project(rows);
    return projected.sort((a, b) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }

  /** Resolves an email/phone or exact name to a user, preferring contact match. */
  async resolve(identifier: string): Promise<UserRow | null> {
    const { rows } = await this.db.query<UserRow>(
      `SELECT ${USER_COLUMNS}
         FROM users u
        WHERE lower(u.phone_or_email) = lower($1) OR lower(u.name) = lower($1)
        ORDER BY CASE WHEN lower(u.phone_or_email) = lower($1) THEN 0 ELSE 1 END,
                 u.id ASC
        LIMIT 1`,
      [identifier],
    );
    return rows[0] ?? null;
  }

  async add(userId: string, friendId: string): Promise<void> {
    await this.db.query(
      `INSERT INTO user_friends (user_id, friend_id)
       VALUES ($1, $2)
       ON CONFLICT (user_id, friend_id) DO NOTHING`,
      [userId, friendId],
    );
  }

  async remove(userId: string, friendId: string): Promise<void> {
    await this.db.query(
      `DELETE FROM user_friends WHERE user_id = $1 AND friend_id = $2`,
      [userId, friendId],
    );
  }

  async isFriend(userId: string, otherId: string): Promise<boolean> {
    const { rows } = await this.db.query(
      `SELECT 1 FROM user_friends WHERE user_id = $1 AND friend_id = $2`,
      [userId, otherId],
    );
    return rows.length > 0;
  }

  private async project(rows: FriendRow[]): Promise<FriendUser[]> {
    const online = await this.presence.onlineUserIds([...new Set(rows.map((row) => row.id))]);
    return rows.map((row) => toFriendUser(row, online.has(row.id)));
  }
}
