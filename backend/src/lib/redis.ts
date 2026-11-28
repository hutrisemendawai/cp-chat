import { Redis } from 'ioredis';

export type Cache = Redis;

export function createRedis(url: string): Redis {
  const redis = new Redis(url, {
    maxRetriesPerRequest: null,
    lazyConnect: false,
  });
  redis.on('error', (error) => {
    console.error('Redis error', error.message);
  });
  return redis;
}

export const redisKeys = {
  connection: (userId: string, deviceId: string) => `conn:${userId}:${deviceId}`,
  connectionsPattern: (userId: string) => `conn:${userId}:*`,
  presenceKey: (userId: string) => `presence:${userId}`,
  conversationMembers: (conversationId: string) => `members:${conversationId}`,
  directConversation: (userA: string, userB: string) => {
    const [low, high] = [userA, userB].sort();
    return `direct:${low}:${high}`;
  },
  rateLimit: (userId: string) => `ratelimit:${userId}`,
  callUser: (userId: string) => `call:user:${userId}`,
  activeCall: (conversationId: string) => `call:active:${conversationId}`,
  channelForNode: (nodeId: string) => `gw:${nodeId}`,
  allNodesChannel: 'gw:all',
};

/**
 * Sends a frame to every gateway node, which delivers it to whichever of the
 * listed users has a local socket. Used for conversation changes (group
 * created, renamed, member added/removed) that are not tied to one recipient.
 */
export async function publishBroadcast(
  redis: Cache,
  userIds: string[],
  frame: Record<string, unknown>,
): Promise<void> {
  if (userIds.length === 0) return;
  await redis.publish(
    redisKeys.allNodesChannel,
    JSON.stringify({ user_ids: userIds, frame }),
  );
}
