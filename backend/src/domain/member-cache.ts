import type { Cache } from '../lib/redis.js';
import { redisKeys } from '../lib/redis.js';
import type { ConversationRepository } from './conversations.js';

/**
 * Redis-backed cache of conversation member ids.
 *
 * Fan-out on write reads this list for every message, so a small TTL cache
 * removes one database round trip per send. Membership changes invalidate
 * eagerly; the TTL is the backstop for a change made by another process or a
 * crash between the write and the invalidation.
 */
export class MemberCache {
  constructor(
    private readonly redis: Cache,
    private readonly conversations: ConversationRepository,
    private readonly ttlSeconds: number,
  ) {}

  async ids(conversationId: string): Promise<string[]> {
    const key = redisKeys.conversationMembers(conversationId);
    const cached = await this.redis.get(key);
    if (cached !== null) {
      try {
        const parsed = JSON.parse(cached) as unknown;
        if (Array.isArray(parsed)) return parsed.filter((id): id is string => typeof id === 'string');
      } catch {
        // Corrupt entry: fall through and rebuild from the database.
      }
    }

    const ids = await this.conversations.memberIds(conversationId);
    await this.redis
      .multi()
      .set(key, JSON.stringify(ids), 'EX', this.ttlSeconds)
      .exec();
    return ids;
  }

  /** Drops the cached list; the next read repopulates it from the database. */
  async invalidate(conversationId: string): Promise<void> {
    await this.redis.del(redisKeys.conversationMembers(conversationId));
  }
}
