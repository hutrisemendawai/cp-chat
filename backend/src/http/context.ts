import type { FastifyReply, FastifyRequest } from 'fastify';

import type { Config } from '../config.js';
import { createBroker, type Broker } from '../lib/broker.js';
import type { Db } from '../lib/db.js';
import { ApiError } from '../lib/errors.js';
import { NotificationService } from '../lib/fcm.js';
import { LiveKitService, type LiveKitClient } from '../lib/livekit.js';
import { createLogger } from '../lib/logger.js';
import { LogStore } from '../lib/log-store.js';
import type { Cache } from '../lib/redis.js';
import { verifyAccessToken } from '../lib/tokens.js';
import { CallRepository } from '../domain/calls.js';
import { CallSignalingService } from '../domain/call-signaling.js';
import { ConversationRepository } from '../domain/conversations.js';
import { DeviceRepository } from '../domain/devices.js';
import { FriendRepository } from '../domain/friends.js';
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
  friends: FriendRepository;
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
  logs: LogStore;
  notifications: NotificationService;
  livekit: LiveKitClient;
  calls: CallRepository;
  callSignaling: CallSignalingService;
};

export type ContextOverrides = {
  notifications?: NotificationService;
  livekit?: LiveKitClient;
};

export function createContext(
  config: Config,
  db: Db,
  redis: Cache,
  logs: LogStore = new LogStore(redis, {
    retentionSeconds: config.LOG_RETENTION_SECONDS,
    maxEntries: config.LOG_MAX_ENTRIES,
    enabled: config.LOG_BUFFER_ENABLED,
  }),
  overrides: ContextOverrides = {},
): AppContext {
  const presence = new PresenceService(redis, db, config.PRESENCE_TTL_SECONDS);
  // Member projections need presence for the status badge; pass the service so
  // a conversation payload carries an accurate `effective_status`.
  const conversations = new ConversationRepository(db, presence);
  const logger = createLogger(config, 'broker');

  // `MESSAGE_STORE=scylla` moves history reads to the wide-column store and
  // dual-writes new messages into it. Postgres keeps `seq` allocation,
  // idempotency, receipts, and full-text search (see domain/messages.ts).
  const scylla =
    config.MESSAGE_STORE === 'scylla'
      ? new ScyllaMessageRepository(createScyllaClient(config), createLogger(config, 'scylla'))
      : null;

  const broker = createBroker(config, redis, config.gatewayNodeId, logger);
  const users = new UserRepository(db);
  const devices = new DeviceRepository(db);
  const notifications =
    overrides.notifications ?? new NotificationService(config, createLogger(config, 'fcm'));
  const livekit =
    overrides.livekit ?? new LiveKitService(config, createLogger(config, 'livekit'));
  const calls = new CallRepository(db);
  const callSignaling = new CallSignalingService(
    config,
    calls,
    livekit,
    users,
    devices,
    notifications,
    broker,
    redis,
    createLogger(config, 'calls'),
  );

  return {
    config,
    db,
    redis,
    // Producers connect lazily, so constructing the broker costs nothing in a
    // process that never publishes (e.g. a REST-only replica).
    broker,
    scylla,
    users,
    friends: new FriendRepository(db, presence),
    refreshTokens: new RefreshTokenRepository(db, config.REFRESH_TOKEN_TTL_SECONDS),
    conversations,
    messages: new MessageRepository(db, {
      scylla,
      logger: createLogger(config, 'messages'),
    }),
    devices,
    keys: new KeyRepository(db),
    media: new MediaRepository(db),
    members: new MemberCache(redis, conversations, config.MEMBERS_CACHE_TTL_SECONDS),
    presence,
    storage: new StorageService(config),
    logs,
    notifications,
    livekit,
    calls,
    callSignaling,
  };
}

declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    deviceId: string;
    startTime?: bigint;
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