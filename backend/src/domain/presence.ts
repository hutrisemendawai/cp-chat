import type { Db } from '../lib/db.js';
import { redisKeys, type Cache } from '../lib/redis.js';

export type PresenceSnapshot = {
  user_id: string;
  online: boolean;
  last_seen_at: Date | null;
};

/**
 * Presence is a Redis key with a TTL, refreshed by the gateway heartbeat. The
 * database keeps `users.last_seen_at`, written when the last device of a user
 * disconnects, so a "last seen" value survives restarts and cache expiry.
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

  async snapshot(userId: string): Promise<PresenceSnapshot | null> {
    const { rows } = await this.db.query<{ last_seen_at: Date | null }>(
      `SELECT last_seen_at FROM users WHERE id = $1`,
      [userId],
    );
    if (!rows[0]) return null;

    return {
      user_id: userId,
      online: await this.isOnline(userId),
      last_seen_at: rows[0].last_seen_at,
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

  /** Distinct users who share at least one conversation with `userId`. */
  async sharedPeerIds(userId: string): Promise<string[]> {
    const { rows } = await this.db.query<{ user_id: string }>(
      `SELECT DISTINCT peer.user_id
         FROM conversation_members mine
         JOIN conversation_members peer
           ON peer.conversation_id = mine.conversation_id
        WHERE mine.user_id = $1 AND peer.user_id <> $1`,
      [userId],
    );
    return rows.map((row) => row.user_id);
  }
}
