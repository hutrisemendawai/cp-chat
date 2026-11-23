import type { Db } from '../lib/db.js';
import { redisKeys, type Cache } from '../lib/redis.js';
import type { EffectiveStatus, UserStatus } from './users.js';

export type PresenceSnapshot = {
  user_id: string;
  /** Backward-compatible alias: `true` whenever `status !== 'offline'`. */
  online: boolean;
  status: EffectiveStatus;
  custom_status: string | null;
  last_seen_at: Date | null;
};

type PresenceRow = {
  status: UserStatus;
  custom_status: string | null;
  last_seen_at: Date | null;
};

/**
 * Resolves the status other users are allowed to see.
 *
 * `invisible` is a privacy setting: it always reads as `offline`, regardless of
 * the Redis key. Otherwise a user with a live key shows their preferred state,
 * and a user with no key is `offline`.
 */
export function effectiveStatus(preference: UserStatus, connected: boolean): EffectiveStatus {
  if (preference === 'invisible') return 'offline';
  return connected ? preference : 'offline';
}

/**
 * Presence is a Redis key with a TTL, refreshed by the gateway heartbeat. The
 * database keeps `users.last_seen_at`, written when the last device of a user
 * disconnects, so a "last seen" value survives restarts and cache expiry.
 *
 * The user's preferred Discord-style state (`online`/`idle`/`dnd`/`invisible`)
 * lives on `users.status`; the Redis key only answers "is a device connected".
 */
export class PresenceService {
  constructor(
    private readonly redis: Cache,
    private readonly db: Db,
    private readonly ttlSeconds: number,
  ) {}

  /** Refreshes the online key; the TTL bounds the damage from a crashed node. */
  async touch(userId: string): Promise<void> {
    await this.redis.set(
      redisKeys.presenceKey(userId),
      Date.now().toString(),
      'EX',
      this.ttlSeconds,
    );
  }

  async isOnline(userId: string): Promise<boolean> {
    return (await this.redis.exists(redisKeys.presenceKey(userId))) === 1;
  }

  /**
   * Bulk online check for a set of users, used when projecting a conversation's
   * member list so every member's badge is accurate in one Redis round trip.
   */
  async onlineUserIds(userIds: string[]): Promise<Set<string>> {
    if (userIds.length === 0) return new Set();
    const values = await this.redis.mget(
      userIds.map((id) => redisKeys.presenceKey(id)),
    );
    const online = new Set<string>();
    values.forEach((value, index) => {
      if (value !== null) online.add(userIds[index]!);
    });
    return online;
  }

  /** The user's stored privacy/status preference, or null when unknown. */
  async profile(userId: string): Promise<PresenceRow | null> {
    const { rows } = await this.db.query<PresenceRow>(
      `SELECT status, custom_status, last_seen_at FROM users WHERE id = $1`,
      [userId],
    );
    return rows[0] ?? null;
  }

  async snapshot(userId: string): Promise<PresenceSnapshot | null> {
    const row = await this.profile(userId);
    if (!row) return null;

    const status = effectiveStatus(row.status, await this.isOnline(userId));
    return {
      user_id: userId,
      online: status !== 'offline',
      status,
      custom_status: row.custom_status,
      last_seen_at: row.last_seen_at,
    };
  }

  /**
   * Clears the online key and durably records the disconnection time. Returns
   * the timestamp so the gateway can fan it out in the offline presence frame.
   */
  async markOffline(userId: string): Promise<Date> {
    await this.redis.del(redisKeys.presenceKey(userId));
    const { rows } = await this.db.query<{ last_seen_at: Date }>(
      `UPDATE users SET last_seen_at = NOW() WHERE id = $1 RETURNING last_seen_at`,
      [userId],
    );
    return rows[0]?.last_seen_at ?? new Date();
  }

  /**
   * Distinct users who should receive this user's presence updates: everyone
   * who shares a conversation with them *and* everyone who has added them as a
   * friend, so the People/Friends list updates live even before a chat exists.
   */
  async sharedPeerIds(userId: string): Promise<string[]> {
    const { rows } = await this.db.query<{ user_id: string }>(
      `SELECT DISTINCT peer.user_id
         FROM conversation_members mine
         JOIN conversation_members peer
           ON peer.conversation_id = mine.conversation_id
        WHERE mine.user_id = $1 AND peer.user_id <> $1
        UNION
       SELECT f.user_id
         FROM user_friends f
        WHERE f.friend_id = $1`,
      [userId],
    );
    return rows.map((row) => row.user_id);
  }
}
