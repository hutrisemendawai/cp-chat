import { randomUUID } from 'node:crypto';

import type { FastifyInstance } from 'fastify';

import { loadConfig, type Config } from '../src/config.js';
import { createContext } from '../src/http/context.js';
import { buildServer } from '../src/http/server.js';
import { createDb, type Db } from '../src/lib/db.js';
import { createLogger } from '../src/lib/logger.js';
import { createRedis, type Cache } from '../src/lib/redis.js';
import { signAccessToken } from '../src/lib/tokens.js';

export const TEST_CONFIG = loadConfig({
  NODE_ENV: 'test',
  LOG_LEVEL: 'fatal',
  DATABASE_URL:
    process.env.TEST_DATABASE_URL ??
    process.env.DATABASE_URL ??
    'postgres://cpchat:cpchat@localhost:5433/cpchat?sslmode=disable',
  REDIS_URL: process.env.TEST_REDIS_URL ?? process.env.REDIS_URL ?? 'redis://localhost:6379/0',
  JWT_SECRET: 'test-secret-that-is-long-enough',
  ACCESS_TOKEN_TTL_SECONDS: '900',
  REFRESH_TOKEN_TTL_SECONDS: '3600',
  // Keep uploaded bytes in-process so media tests need no MinIO container.
  S3_DRIVER: 'memory',
});

export type TestHarness = {
  app: FastifyInstance;
  db: Db;
  redis: Cache;
  config: Config;
  close: () => Promise<void>;
};

export async function createHarness(): Promise<TestHarness> {
  const config = TEST_CONFIG;
  const db = createDb(config.DATABASE_URL);
  const redis = createRedis(config.REDIS_URL);
  const ctx = createContext(config, db, redis);
  const app = buildServer(ctx, createLogger(config, 'test'));
  await app.ready();

  return {
    app,
    db,
    redis,
    config,
    close: async () => {
      await app.close();
      redis.disconnect();
      await db.end();
    },
  };
}

export type TestUser = {
  id: string;
  accessToken: string;
  refreshToken: string;
  email: string;
  deviceId: string;
};

export async function registerUser(
  harness: TestHarness,
  name = 'Test User',
): Promise<TestUser> {
  const email = `${name.toLowerCase().replace(/\s+/g, '.')}+${randomUUID()}@example.com`;
  const deviceId = `device-${randomUUID()}`;
  const response = await harness.app.inject({
    method: 'POST',
    url: '/api/v1/auth/register',
    headers: { 'x-device-id': deviceId },
    payload: { phone_or_email: email, name, password: 'password123' },
  });

  if (response.statusCode !== 201) {
    throw new Error(`registration failed: ${response.statusCode} ${response.body}`);
  }
  const body = response.json();
  return {
    id: body.user.id,
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
    email,
    deviceId,
  };
}

export function auth(user: TestUser) {
  return { authorization: `Bearer ${user.accessToken}` };
}

export async function createDirect(
  harness: TestHarness,
  from: TestUser,
  to: TestUser,
): Promise<string> {
  const response = await harness.app.inject({
    method: 'POST',
    url: '/api/v1/conversations',
    headers: auth(from),
    payload: { type: 'direct', member_ids: [to.id] },
  });
  if (response.statusCode !== 201) {
    throw new Error(`conversation failed: ${response.statusCode} ${response.body}`);
  }
  return response.json().id;
}

export async function createGroup(
  harness: TestHarness,
  creator: TestUser,
  members: TestUser[],
  name = 'Test Group',
): Promise<string> {
  const response = await harness.app.inject({
    method: 'POST',
    url: '/api/v1/conversations',
    headers: auth(creator),
    payload: { type: 'group', name, member_ids: members.map((member) => member.id) },
  });
  if (response.statusCode !== 201) {
    throw new Error(`group failed: ${response.statusCode} ${response.body}`);
  }
  return response.json().id;
}

export async function truncateAll(db: Db): Promise<void> {
  await db.query(
    `TRUNCATE user_friends, media_objects, message_receipts, messages, conversation_members,
              conversations, device_tokens, refresh_tokens, users RESTART IDENTITY CASCADE`,
  );
}

/**
 * Inserts users straight into the table. Bulk fixtures (e.g. filling a group to
 * its 500-member limit) should not pay the scrypt cost of a real registration.
 */
export async function seedUsers(harness: TestHarness, count: number): Promise<TestUser[]> {
  const rows = Array.from({ length: count }, (_, index) => ({
    email: `seed-${index}-${randomUUID()}@example.com`,
    name: `Seed ${index}`,
    deviceId: `seed-device-${index}`,
  }));

  const { rows: inserted } = await harness.db.query<{ id: string; phone_or_email: string }>(
    `INSERT INTO users (phone_or_email, name, password_hash)
     SELECT email, name, 'scrypt$16$8$1$deadbeef$deadbeef'
       FROM unnest($1::text[], $2::text[]) AS t(email, name)
     RETURNING id, phone_or_email`,
    [rows.map((row) => row.email), rows.map((row) => row.name)],
  );

  return inserted.map((row, index) => ({
    id: row.id,
    email: row.phone_or_email,
    accessToken: signAccessToken(row.id, rows[index]!.deviceId, TEST_CONFIG),
    refreshToken: '',
    deviceId: rows[index]!.deviceId,
  }));
}
