import type { FastifyReply, FastifyRequest } from 'fastify';

import type { Config } from '../config.js';
import { createBroker, type Broker } from '../lib/broker.js';
import type { Db } from '../lib/db.js';
import { ApiError } from '../lib/errors.js';
import { createLogger } from '../lib/logger.js';
import type { Cache } from '../lib/redis.js';
import { verifyAccessToken } from '../lib/tokens.js';
import { ConversationRepository } from '../domain/conversations.js';
import { DeviceRepository } from '../domain/devices.js';
import { KeyRepository } from '../domain/keys.js';
import { MediaRepository } from '../domain/media.js';
import { MemberCache } from '../domain/member-cache.js';
import { MessageRepository } from '../domain/messages.js';
import { PresenceService } from '../domain/presence.js';
import { RefreshTokenRepository } from '../domain/refresh-tokens.js';
import { createScyllaClient, ScyllaMessageRepository } from '../domain/scylla-messages.js';
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
  presence: PresenceService;
  storage: StorageService;
  broker: Broker;
  scylla: ScyllaMessageRepository | null;
  keys: KeyRepository;
};

export function createContext(config: Config, db: Db, redis: Cache): AppContext {
  const conversations = new ConversationRepository(db);
  const logger = createLogger(config, 'broker');

  // `MESSAGE_STORE=scylla` moves history reads to the wide-column store and
  // dual-writes new messages into it. Postgres keeps `seq` allocation,
  // idempotency, receipts, and full-text search (see domain/messages.ts).
  const scylla =
    config.MESSAGE_STORE === 'scylla'
      ? new ScyllaMessageRepository(createScyllaClient(config), createLogger(config, 'scylla'))
      : null;

  return {
    config,
    db,
    redis,
    // Producers connect lazily, so constructing the broker costs nothing in a
    // process that never publishes (e.g. a REST-only replica).
    broker: createBroker(config, redis, config.gatewayNodeId, logger),
    scylla,
    users: new UserRepository(db),
    refreshTokens: new RefreshTokenRepository(db, config.REFRESH_TOKEN_TTL_SECONDS),
    conversations,
    messages: new MessageRepository(db, {
      scylla,
      logger: createLogger(config, 'messages'),
    }),
    devices: new DeviceRepository(db),
    keys: new KeyRepository(db),
    media: new MediaRepository(db),
    members: new MemberCache(redis, conversations, config.MEMBERS_CACHE_TTL_SECONDS),
    presence: new PresenceService(redis, db, config.PRESENCE_TTL_SECONDS),
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