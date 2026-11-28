import { createHash } from 'node:crypto';

import jwt from 'jsonwebtoken';
import { AccessToken, WebhookReceiver } from 'livekit-server-sdk';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { loadConfig } from '../src/config.js';
import { createContext, type AppContext } from '../src/http/context.js';
import { buildServer } from '../src/http/server.js';
import { createDb } from '../src/lib/db.js';
import { ApiError } from '../src/lib/errors.js';
import type { LiveKitClient } from '../src/lib/livekit.js';
import { createLogger } from '../src/lib/logger.js';
import { createRedis } from '../src/lib/redis.js';
import {
  TEST_CONFIG,
  auth,
  createDirect,
  createGroup,
  registerUser,
  truncateAll,
  type TestHarness,
} from './helpers.js';

const TEST_LK_KEY = 'devkey_test';
const TEST_LK_SECRET = 'devsecret_test_at_least_32_characters_long';

class FakeLiveKitClient implements LiveKitClient {
  readonly enabled = true;
  readonly publicUrl = 'wss://livekit.test.local';
  readonly createdRooms = new Set<string>();
  readonly deletedRooms: string[] = [];
  private readonly receiver = new WebhookReceiver(TEST_LK_KEY, TEST_LK_SECRET);

  async createRoom(roomName: string): Promise<void> {
    this.createdRooms.add(roomName);
  }

  async deleteRoom(roomName: string): Promise<void> {
    this.createdRooms.delete(roomName);
    this.deletedRooms.push(roomName);
  }

  async listRooms(names?: string[]): Promise<string[]> {
    if (!names) return [...this.createdRooms];
    return names.filter((name) => this.createdRooms.has(name));
  }

  async mintToken(input: {
    roomName: string;
    userId: string;
    displayName: string;
    metadata?: string;
  }): Promise<{ token: string; expiresIn: number }> {
    const token = new AccessToken(TEST_LK_KEY, TEST_LK_SECRET, {
      identity: input.userId,
      name: input.displayName,
      metadata: input.metadata,
      ttl: 600,
    });
    token.addGrant({
      roomJoin: true,
      room: input.roomName,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      roomCreate: false,
    });
    return { token: await token.toJwt(), expiresIn: 600 };
  }

  async verifyWebhook(rawBody: string, authHeader: string) {
    if (!authHeader) {
      throw new ApiError('unauthorized', 'Missing LiveKit webhook Authorization header');
    }
    try {
      return await this.receiver.receive(rawBody, authHeader);
    } catch {
      throw new ApiError('unauthorized', 'Invalid LiveKit webhook signature');
    }
  }
}

function signLiveKitWebhook(rawBody: string, apiKey = TEST_LK_KEY, secret = TEST_LK_SECRET): string {
  const sha256 = createHash('sha256').update(rawBody).digest('base64');
  return jwt.sign({ sha256 }, secret, {
    issuer: apiKey,
    expiresIn: '5m',
    algorithm: 'HS256',
  });
}

describe('Voice & Video Calls (LiveKit orchestration)', () => {
  let harness: TestHarness;
  let ctx: AppContext;
  let fakeLiveKit: FakeLiveKitClient;

  beforeAll(async () => {
    const config = loadConfig({
      ...process.env,
      NODE_ENV: 'test',
      LOG_LEVEL: 'fatal',
      DATABASE_URL: TEST_CONFIG.DATABASE_URL,
      REDIS_URL: TEST_CONFIG.REDIS_URL,
      JWT_SECRET: TEST_CONFIG.JWT_SECRET,
      S3_DRIVER: 'memory',
      LIVEKIT_API_KEY: TEST_LK_KEY,
      LIVEKIT_API_SECRET: TEST_LK_SECRET,
      LIVEKIT_PUBLIC_URL: 'wss://livekit.test.local',
      CALL_MAX_GROUP_PARTICIPANTS: '3',
    });
    const db = createDb(config.DATABASE_URL);
    const redis = createRedis(config.REDIS_URL);
    fakeLiveKit = new FakeLiveKitClient();
    ctx = createContext(config, db, redis, undefined, { livekit: fakeLiveKit });
    const app = buildServer(ctx, createLogger(config, 'test-calls'));
    await app.ready();

    harness = {
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
  });

  afterAll(async () => {
    await harness.close();
  });

  beforeEach(async () => {
    await truncateAll(harness.db);
    fakeLiveKit.createdRooms.clear();
    fakeLiveKit.deletedRooms.length = 0;
  });

  it('runs a full 1:1 call lifecycle (start -> accept -> refresh token -> leave)', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const convId = await createDirect(harness, alice, bob);

    const startRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/calls`,
      headers: auth(alice),
      payload: { media_type: 'video' },
    });
    expect(startRes.statusCode).toBe(201);
    const started = startRes.json();
    expect(started.call.type).toBe('1on1');
    expect(started.call.media_type).toBe('video');
    expect(started.call.status).toBe('ringing');
    expect(started.livekit_url).toBe('wss://livekit.test.local');
    expect(typeof started.token).toBe('string');
    expect(fakeLiveKit.createdRooms.has(started.call.room_name)).toBe(true);

    const decoded = jwt.verify(started.token, TEST_LK_SECRET) as {
      sub: string;
      video?: { room?: string; roomJoin?: boolean; roomCreate?: boolean };
    };
    expect(decoded.sub).toBe(alice.id);
    expect(decoded.video?.room).toBe(started.call.room_name);
    expect(decoded.video?.roomJoin).toBe(true);
    expect(decoded.video?.roomCreate).toBe(false);

    const acceptRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${started.call.id}/accept`,
      headers: auth(bob),
    });
    expect(acceptRes.statusCode).toBe(200);
    const accepted = acceptRes.json();
    expect(accepted.call.status).toBe('active');
    expect(accepted.call.answered_at).toBeTruthy();

    const refreshRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${started.call.id}/token`,
      headers: auth(bob),
    });
    expect(refreshRes.statusCode).toBe(200);
    expect(refreshRes.json().expires_in).toBe(600);

    const leaveRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${started.call.id}/leave`,
      headers: auth(alice),
    });
    expect(leaveRes.statusCode).toBe(204);
    expect(fakeLiveKit.deletedRooms).toContain(started.call.room_name);

    const activeRes = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/active-call`,
      headers: auth(bob),
    });
    expect(activeRes.statusCode).toBe(200);
    expect(activeRes.json().active_call).toBeNull();
  });

  it('rejects a 1:1 invite with 409 callee_busy when callee is already in another call', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const convAB = await createDirect(harness, alice, bob);
    const convCB = await createDirect(harness, carol, bob);

    const first = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convAB}/calls`,
      headers: auth(alice),
      payload: { media_type: 'voice' },
    });
    expect(first.statusCode).toBe(201);

    const second = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convCB}/calls`,
      headers: auth(carol),
      payload: { media_type: 'voice' },
    });
    expect(second.statusCode).toBe(409);
    expect(second.json().error.code).toBe('callee_busy');
  });

  it('resolves cancel-vs-accept race cleanly with 409 call_already_ended', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const convId = await createDirect(harness, alice, bob);

    const startRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/calls`,
      headers: auth(alice),
      payload: { media_type: 'voice' },
    });
    const callId = startRes.json().call.id as string;

    const cancelRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/cancel`,
      headers: auth(alice),
    });
    expect(cancelRes.statusCode).toBe(204);

    const acceptRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/accept`,
      headers: auth(bob),
    });
    expect(acceptRes.statusCode).toBe(409);
    expect(acceptRes.json().error.code).toBe('call_already_ended');
  });

  it('converges simultaneous 1:1 calls between the same pair into one active call', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const convId = await createDirect(harness, alice, bob);

    const fromAlice = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/calls`,
      headers: auth(alice),
      payload: { media_type: 'voice' },
    });
    expect(fromAlice.statusCode).toBe(201);

    const fromBob = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/calls`,
      headers: auth(bob),
      payload: { media_type: 'voice' },
    });
    expect(fromBob.statusCode).toBe(200);
    expect(fromBob.json().call.id).toBe(fromAlice.json().call.id);
    expect(fromBob.json().call.status).toBe('active');
    expect(fromBob.json().joined_existing).toBe(true);
  });

  it('sweeps expired 1:1 ringing calls as missed', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const convId = await createDirect(harness, alice, bob);

    const startRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/calls`,
      headers: auth(alice),
      payload: { media_type: 'voice' },
    });
    const callId = startRes.json().call.id as string;

    await harness.db.query(
      `UPDATE calls SET ring_expires_at = NOW() - INTERVAL '5 seconds' WHERE id = $1`,
      [callId],
    );

    const swept = await ctx.callSignaling.sweepExpiredRinging();
    expect(swept).toBe(1);

    const row = await ctx.calls.findById(callId);
    expect(row?.status).toBe('missed');
    expect(row?.end_reason).toBe('timeout');
  });

  it('converges concurrent group call starts, enforces cap/membership, and keeps call alive on single leave', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const dave = await registerUser(harness, 'Dave');
    const groupId = await createGroup(harness, alice, [bob, carol, dave], 'Engineering');

    // Concurrent starts by Alice and Bob must converge onto the exact same room.
    const [resA, resB] = await Promise.all([
      harness.app.inject({
        method: 'POST',
        url: `/api/v1/conversations/${groupId}/calls`,
        headers: auth(alice),
        payload: { media_type: 'video' },
      }),
      harness.app.inject({
        method: 'POST',
        url: `/api/v1/conversations/${groupId}/calls`,
        headers: auth(bob),
        payload: { media_type: 'video' },
      }),
    ]);

    expect([200, 201]).toContain(resA.statusCode);
    expect([200, 201]).toContain(resB.statusCode);
    const callId = resA.json().call.id as string;
    const roomName = resA.json().call.room_name as string;
    expect(resB.json().call.id).toBe(callId);
    expect(resB.json().call.room_name).toBe(roomName);

    // Carol late-joins via /join (hits cap of 3 configured in beforeAll).
    const joinCarol = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/join`,
      headers: auth(carol),
    });
    expect(joinCarol.statusCode).toBe(200);
    expect(joinCarol.json().call.participant_count).toBe(3);

    // Dave is blocked by CALL_MAX_GROUP_PARTICIPANTS=3.
    const joinDaveFull = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/join`,
      headers: auth(dave),
    });
    expect(joinDaveFull.statusCode).toBe(409);
    expect(joinDaveFull.json().error.code).toBe('call_full');

    // Alice leaves — group call stays active!
    const leaveAlice = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/leave`,
      headers: auth(alice),
    });
    expect(leaveAlice.statusCode).toBe(204);

    const activeBanner = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}/active-call`,
      headers: auth(bob),
    });
    expect(activeBanner.statusCode).toBe(200);
    expect(activeBanner.json().active_call.id).toBe(callId);
    expect(activeBanner.json().active_call.participant_count).toBe(2);

    // Removing Dave from the group immediately blocks him from joining even after a slot opened.
    const removeDave = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${dave.id}`,
      headers: auth(alice),
    });
    expect(removeDave.statusCode).toBe(204);

    const joinDaveRemoved = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/calls/${callId}/join`,
      headers: auth(dave),
    });
    expect(joinDaveRemoved.statusCode).toBe(403);
    expect(joinDaveRemoved.json().error.code).toBe('not_a_member');

    // Unsigned LiveKit webhook is rejected with 401.
    const badWebhook = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/webhooks/livekit',
      headers: { 'content-type': 'application/webhook+json' },
      payload: JSON.stringify({ event: 'room_finished', room: { name: roomName } }),
    });
    expect(badWebhook.statusCode).toBe(401);

    // Signed participant_joined & room_finished webhooks reconcile DB state cleanly.
    const joinedBody = JSON.stringify({
      event: 'participant_joined',
      room: { name: roomName },
      participant: { identity: bob.id },
    });
    const joinedWebhook = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/webhooks/livekit',
      headers: {
        'content-type': 'application/webhook+json',
        authorization: signLiveKitWebhook(joinedBody),
      },
      payload: joinedBody,
    });
    expect(joinedWebhook.statusCode).toBe(200);

    const finishedBody = JSON.stringify({
      event: 'room_finished',
      room: { name: roomName },
    });
    const finishedWebhook = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/webhooks/livekit',
      headers: {
        'content-type': 'application/webhook+json',
        authorization: signLiveKitWebhook(finishedBody),
      },
      payload: finishedBody,
    });
    expect(finishedWebhook.statusCode).toBe(200);

    const afterFinish = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}/active-call`,
      headers: auth(bob),
    });
    expect(afterFinish.json().active_call).toBeNull();
  });
});
