import type { FastifyReply, FastifyRequest } from 'fastify';

import type { Config } from '../config.js';
import type { Db } from '../lib/db.js';
import { ApiError } from '../lib/errors.js';
import type { Cache } from '../lib/redis.js';
import { verifyAccessToken } from '../lib/tokens.js';
import { ConversationRepository } from '../domain/conversations.js';
import { DeviceRepository } from '../domain/devices.js';
import { MediaRepository } from '../domain/media.js';
import { MemberCache } from '../domain/member-cache.js';
import { MessageRepository } from '../domain/messages.js';
import { RefreshTokenRepository } from '../domain/refresh-tokens.js';
import { UserRepository } from '../domain/users.js';
import { StorageService } from '../lib/storage.js';

export type AppContext = {
  config: Config;
  db: Db;
  redis: Cache;
  users: UserRepository;
  refreshTokens: RefreshTokenRepository;
  conversations: ConversationRepository;
  messages: MessageRepository;
  devices: DeviceRepository;
  media: MediaRepository;
  members: MemberCache;
  storage: StorageService;
};

export function createContext(config: Config, db: Db, redis: Cache): AppContext {
  const conversations = new ConversationRepository(db);
  return {
    config,
    db,
    redis,
    users: new UserRepository(db),
    refreshTokens: new RefreshTokenRepository(db, config.REFRESH_TOKEN_TTL_SECONDS),
    conversations,
    messages: new MessageRepository(db),
    devices: new DeviceRepository(db),
    media: new MediaRepository(db),
    members: new MemberCache(redis, conversations, config.MEMBERS_CACHE_TTL_SECONDS),
    storage: new StorageService(config),
  };
}

declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    deviceId: string;
  }
}

export function requireAuth(request: FastifyRequest, config: Config): void {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    throw new ApiError('unauthorized', 'Missing bearer token');
  }
  const payload = verifyAccessToken(header.slice('Bearer '.length).trim(), config);
  request.userId = payload.sub;
  request.deviceId = payload.device_id;
}

export function sendError(reply: FastifyReply, error: unknown) {
  if (error instanceof ApiError) {
    reply.status(error.status).send(error.toBody());
    return;
  }
  reply.status(500).send({
    error: { code: 'internal_error', message: 'Internal server error' },
  });
}