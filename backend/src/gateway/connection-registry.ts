import type { Cache } from '../lib/redis.js';
import { redisKeys } from '../lib/redis.js';

/**
 * Tracks which gateway node owns each `(user, device)` socket.
 *
 * `conn:{user}:{device}` is a plain string so a node can be discovered in one
 * round trip; `conns:{user}` is a set of device ids so fan-out can find every
 * device without a SCAN. Both carry a TTL refreshed by the heartbeat, which
 * bounds the damage from a node crashing without cleaning up.
 */
export class ConnectionRegistry {
  constructor(
    private readonly redis: Cache,
    private readonly nodeId: string,
    private readonly ttlSeconds: number,
  ) {}

  async register(userId: string, deviceId: string): Promise<void> {
    const key = redisKeys.connection(userId, deviceId);
    await this.redis
      .multi()
      .set(key, this.nodeId, 'EX', this.ttlSeconds)
      .sadd(`conns:${userId}`, deviceId)
      .expire(`conns:${userId}`, this.ttlSeconds)
      .exec();
  }

  async refresh(userId: string, deviceId: string): Promise<void> {
    await this.redis
      .multi()
      .expire(redisKeys.connection(userId, deviceId), this.ttlSeconds)
      .expire(`conns:${userId}`, this.ttlSeconds)
      .exec();
  }

  async unregister(userId: string, deviceId: string): Promise<void> {
    await this.redis
      .multi()
      .del(redisKeys.connection(userId, deviceId))
      .srem(`conns:${userId}`, deviceId)
      .exec();
  }

  async devices(userId: string): Promise<string[]> {
    return this.redis.smembers(`conns:${userId}`);
  }

  /** Device ids whose `conn:` key still points at a live node. */
  async liveDevices(userId: string): Promise<string[]> {
    const devices = await this.devices(userId);
    if (devices.length === 0) return [];
    const nodes = await Promise.all(
      devices.map((deviceId) => this.redis.get(redisKeys.connection(userId, deviceId))),
    );
    return devices.filter((_, index) => nodes[index] !== null);
  }

  async isOnline(userId: string): Promise<boolean> {
    return (await this.liveDevices(userId)).length > 0;
  }
}
