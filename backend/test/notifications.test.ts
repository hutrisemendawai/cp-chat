import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { createContext } from '../src/http/context.js';
import {
  MAX_FCM_DATA_BYTES,
  NotificationService,
  buildDataOnlyMap,
  type PushPayload,
} from '../src/lib/fcm.js';
import { createLogger } from '../src/lib/logger.js';
import {
  TEST_CONFIG,
  auth,
  createDirect,
  createGroup,
  createHarness,
  registerUser,
  truncateAll,
  type TestHarness,
  type TestUser,
} from './helpers.js';

let harness: TestHarness;
let gateway: ChatGateway;
let server: Server;
let port: number;

/** Records pushes and lets each test decide which installations FCM reports dead. */
const pushes: { mode: 'legacy' | 'data_only'; fids: string[]; payload: PushPayload }[] = [];
let staleToReturn: string[] = [];
const fakeNotifications = {
  enabled: true,
  initialize: async () => undefined,
  notify: async (fids: string[], payload: PushPayload) => {
    pushes.push({ mode: 'legacy', fids, payload });
    return staleToReturn.filter((fid) => fids.includes(fid));
  },
  notifyDataOnly: async (fids: string[], payload: PushPayload) => {
    pushes.push({ mode: 'data_only', fids, payload });
    return staleToReturn.filter((fid) => fids.includes(fid));
  },
} as unknown as NotificationService;

beforeAll(async () => {
  harness = await createHarness();
  const ctx = createContext(TEST_CONFIG, harness.db, harness.redis);
  gateway = new ChatGateway(
    TEST_CONFIG,
    ctx,
    ctx.broker,
    fakeNotifications,
    createLogger(TEST_CONFIG, 'test'),
  );
  await gateway.start();

  server = createServer();
  server.on('upgrade', (request, socket, head) => gateway.handleUpgrade(request, socket, head));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = (server.address() as { port: number }).port;
});

afterAll(async () => {
  await gateway.stop();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
  pushes.length = 0;
  staleToReturn = [];
});

type TestSocket = {
  send: (frame: unknown) => void;
  wait: (
    match: (frame: Record<string, unknown>) => boolean,
    timeoutMs?: number,
  ) => Promise<Record<string, unknown>>;
  close: () => void;
};

async function eventually<T>(check: () => T | Promise<T>, timeoutMs = 3000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() - start > timeoutMs) throw new Error('condition was never met');
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function waitForRegistration(user: TestUser): Promise<void> {
  await eventually(async () => (await harness.redis.get(`conn:${user.id}:${user.deviceId}`)) !== null);
}

function connect(user: TestUser): Promise<TestSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(user.accessToken)}`,
    );
    const inbox: Record<string, unknown>[] = [];
    const waiters: {
      match: (frame: Record<string, unknown>) => boolean;
      resolve: (frame: Record<string, unknown>) => void;
      timer: NodeJS.Timeout;
    }[] = [];

    ws.on('message', (data) => {
      const frame = JSON.parse(data.toString()) as Record<string, unknown>;
      const index = waiters.findIndex((waiter) => waiter.match(frame));
      if (index >= 0) {
        const [waiter] = waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
      } else {
        inbox.push(frame);
      }
    });
    ws.on('error', reject);
    ws.on('open', () => {
      const socket: TestSocket = {
        send: (frame) => ws.send(JSON.stringify(frame)),
        wait: (match, timeoutMs = 4000) =>
          new Promise((res, rej) => {
            const existing = inbox.findIndex(match);
            if (existing >= 0) {
              res(inbox.splice(existing, 1)[0]!);
              return;
            }
            const timer = setTimeout(() => {
              const index = waiters.findIndex((waiter) => waiter.resolve === res);
              if (index >= 0) waiters.splice(index, 1);
              rej(new Error('timed out'));
            }, timeoutMs);
            waiters.push({ match, resolve: res, timer });
          }),
        close: () => ws.close(),
      };
      waitForRegistration(user).then(() => resolve(socket), reject);
    });
  });
}

async function seedDevice(
  user: TestUser,
  deviceId: string,
  fcmToken: string,
  pushVersion = 1,
): Promise<void> {
  await harness.db.query(
    `INSERT INTO device_tokens (user_id, device_id, fcm_token, push_version) VALUES ($1, $2, $3, $4)`,
    [user.id, deviceId, fcmToken, pushVersion],
  );
}

describe('fcm dispatch', () => {
  it('pushes to an offline recipient with the sender metadata', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, 'bob-phone', 'bob-fid');

    const aliceSocket = await connect(alice);
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'are you there?',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    const push = await eventually(() => pushes[0]);
    expect(push.fids).toEqual(['bob-fid']);
    expect(push.payload).toMatchObject({
      conversationId,
      senderId: alice.id,
      senderName: 'Alice',
      recipientUserId: bob.id,
      type: 'text',
      body: 'are you there?',
    });

    aliceSocket.close();
  });

  it('does not push to a recipient device with a live socket', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, bob.deviceId, 'bob-fid');

    const aliceSocket = await connect(alice);
    const bobSocket = await connect(bob);
    const clientMsgId = randomUUID();
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'ping',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');
    await bobSocket.wait((item) => item.type === 'message' && item.client_msg_id === clientMsgId);

    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(pushes).toHaveLength(0);

    aliceSocket.close();
    bobSocket.close();
  });

  it('pushes to an offline secondary device even when another device has a live socket', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, bob.deviceId, 'bob-online-fid', 2);
    await seedDevice(bob, 'bob-offline-phone', 'bob-offline-fid', 2);

    const aliceSocket = await connect(alice);
    const bobSocket = await connect(bob);
    const clientMsgId = randomUUID();
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: 'multi-device ping',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');
    await bobSocket.wait((item) => item.type === 'message' && item.client_msg_id === clientMsgId);

    const push = await eventually(() => pushes[0]);
    expect(push.mode).toBe('data_only');
    expect(push.fids).toEqual(['bob-offline-fid']);

    aliceSocket.close();
    bobSocket.close();
  });

  it('pushes when the only routing entry is stale (socket gone without a close frame)', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, 'bob-phone', 'bob-fid');

    // A device still listed in the per-user set, but its `conn:` key has expired
    // (the node that owned it crashed or the app was killed). It must not count
    // as online, so the message still falls through to FCM.
    await harness.redis.sadd(`conns:${bob.id}`, 'bob-ghost-device');

    const aliceSocket = await connect(alice);
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'hello?',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    const push = await eventually(() => pushes[0]);
    expect(push.fids).toEqual(['bob-fid']);

    aliceSocket.close();
  });

  it('prunes an installation FCM reports as unregistered', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, 'bob-phone', 'bob-dead-fid');
    staleToReturn = ['bob-dead-fid'];

    const aliceSocket = await connect(alice);
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'gone',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    await eventually(async () => {
      const { rows } = await harness.db.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM device_tokens WHERE fcm_token = 'bob-dead-fid'`,
      );
      return rows[0]!.count === '0';
    });

    aliceSocket.close();
  });

  it('sends high-priority data-only v2 payload with E2EE ciphertext to push_version=2 devices', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, 'bob-v2', 'bob-v2-fid', 2);

    const envelope = `e2ee:v1:${JSON.stringify({
      v: 1,
      ik: 'aWstYWxpY2U=',
      ek: 'ZWstYWxpY2U=',
      spk: 1,
      i: 0,
      ct: 'Y2lwaGVydGV4dA==',
      n: 'bm9uY2UxMjM0NTY=',
      m: 'bWFjMTIzNDU2Nzg5MDEyMzQ1Ng==',
    })}`;
    const clientMsgId = randomUUID();

    const aliceSocket = await connect(alice);
    aliceSocket.send({
      type: 'send',
      conversation_id: conversationId,
      client_msg_id: clientMsgId,
      msg_type: 'text',
      content: envelope,
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    const push = await eventually(() => pushes[0]);
    expect(push.mode).toBe('data_only');
    expect(push.fids).toEqual(['bob-v2-fid']);
    expect(push.payload).toMatchObject({
      conversationId,
      conversationType: 'direct',
      clientMsgId,
      seq: 1,
      senderId: alice.id,
      senderName: 'Alice',
      recipientUserId: bob.id,
      type: 'text',
      body: 'Encrypted message',
      content: envelope,
    });

    const dataMap = buildDataOnlyMap(push.payload);
    expect(dataMap).toMatchObject({
      push_schema: '2',
      conversation_id: conversationId,
      conversation_type: 'direct',
      client_msg_id: clientMsgId,
      seq: '1',
      msg_type: 'text',
      type: 'text',
      content: envelope,
    });
    expect(dataMap.content_omitted).toBeUndefined();

    aliceSocket.close();
  });

  it('splits mixed v1 and v2 devices for the same user and prunes stale FIDs from both', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const groupId = await createGroup(harness, alice, [bob], 'Team Alpha');
    await seedDevice(bob, 'bob-old', 'bob-v1-fid', 1);
    await seedDevice(bob, 'bob-new', 'bob-v2-fid', 2);
    staleToReturn = ['bob-v1-fid', 'bob-v2-fid'];

    const aliceSocket = await connect(alice);
    aliceSocket.send({
      type: 'send',
      conversation_id: groupId,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'hello group',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    await eventually(() => pushes.length === 2);
    const v2Push = pushes.find((p) => p.mode === 'data_only');
    const v1Push = pushes.find((p) => p.mode === 'legacy');
    expect(v2Push?.fids).toEqual(['bob-v2-fid']);
    expect(v2Push?.payload.conversationType).toBe('group');
    expect(v2Push?.payload.conversationName).toBe('Team Alpha');
    expect(v2Push?.payload.content).toBe('hello group');
    expect(v1Push?.fids).toEqual(['bob-v1-fid']);

    await eventually(async () => {
      const { rows } = await harness.db.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM device_tokens WHERE user_id = $1`,
        [bob.id],
      );
      return rows[0]!.count === '0';
    });

    aliceSocket.close();
  });

  it('persists push_version via POST /api/v1/devices/fcm-token (default 1, explicit 2)', async () => {
    const bob = await registerUser(harness, 'Bob');

    const r1 = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/devices/fcm-token',
      headers: auth(bob),
      payload: { fcm_token: 'fid-legacy', device_id: 'dev-1' },
    });
    expect(r1.statusCode).toBe(204);

    const r2 = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/devices/fcm-token',
      headers: auth(bob),
      payload: { fcm_token: 'fid-modern', device_id: 'dev-2', push_version: 2 },
    });
    expect(r2.statusCode).toBe(204);

    const { rows } = await harness.db.query<{ device_id: string; push_version: number }>(
      `SELECT device_id, push_version FROM device_tokens WHERE user_id = $1 ORDER BY device_id`,
      [bob.id],
    );
    expect(rows).toEqual([
      { device_id: 'dev-1', push_version: 1 },
      { device_id: 'dev-2', push_version: 2 },
    ]);
  });

  it('omits oversized content (>3500 UTF-8 bytes) and sets content_omitted=true under 4KB', () => {
    const hugeContent = `e2ee:v1:${'x'.repeat(3800)}`;
    const data = buildDataOnlyMap({
      title: 'Alice',
      body: 'Encrypted message',
      conversationId: '11111111-1111-4111-8111-111111111111',
      conversationType: 'direct',
      messageId: '22222222-2222-4222-8222-222222222222',
      clientMsgId: '33333333-3333-4333-8333-333333333333',
      seq: 42,
      senderId: '44444444-4444-4444-8444-444444444444',
      senderName: 'Alice',
      recipientUserId: '55555555-5555-4555-8555-555555555555',
      conversationName: '',
      type: 'text',
      createdAt: '2026-11-26T12:00:00.000Z',
      content: hugeContent,
    });

    expect(data.content).toBeUndefined();
    expect(data.content_omitted).toBe('true');
    expect(data.push_schema).toBe('2');
    expect(Buffer.byteLength(JSON.stringify(data), 'utf8')).toBeLessThanOrEqual(
      MAX_FCM_DATA_BYTES,
    );
    expect(Buffer.byteLength(JSON.stringify(data), 'utf8')).toBeLessThan(4096);
  });

  it('notifyDataOnly sends high-priority data-only multicast with no notification block', async () => {
    const sentMessages: Record<string, unknown>[] = [];
    const service = new NotificationService(TEST_CONFIG, createLogger(TEST_CONFIG, 'test'));
    (service as unknown as { messaging: unknown }).messaging = {
      sendEachForMulticast: async (message: Record<string, unknown>) => {
        sentMessages.push(message);
        return { successCount: 1, failureCount: 0, responses: [{ success: true }] };
      },
    };

    const stale = await service.notifyDataOnly(['bob-v2-fid'], {
      title: 'Alice',
      body: 'Encrypted message',
      conversationId: 'c1',
      conversationType: 'direct',
      messageId: 'm1',
      clientMsgId: 'cm1',
      seq: 7,
      senderId: 'alice',
      senderName: 'Alice',
      recipientUserId: 'bob',
      conversationName: '',
      type: 'text',
      createdAt: '2026-11-26T12:00:00.000Z',
      content: 'e2ee:v1:{"v":1}',
    });

    expect(stale).toEqual([]);
    expect(sentMessages).toHaveLength(1);
    const msg = sentMessages[0]!;
    expect(msg.notification).toBeUndefined();
    expect((msg.android as Record<string, unknown>).priority).toBe('high');
    expect((msg.android as Record<string, unknown>).notification).toBeUndefined();
    expect((msg.data as Record<string, string>).push_schema).toBe('2');
    expect((msg.data as Record<string, string>).content).toBe('e2ee:v1:{"v":1}');
  });

  it('does not prune device tokens on messaging/invalid-argument and chunks batches at 500', async () => {
    const chunkSizes: number[] = [];
    const service = new NotificationService(TEST_CONFIG, createLogger(TEST_CONFIG, 'test'));
    (service as unknown as { messaging: unknown }).messaging = {
      sendEachForMulticast: async (message: { fids: string[] }) => {
        chunkSizes.push(message.fids.length);
        return {
          successCount: message.fids.length - 1,
          failureCount: 1,
          responses: message.fids.map((_, i) =>
            i === 0
              ? { success: false, error: { code: 'messaging/invalid-argument' } }
              : { success: true },
          ),
        };
      },
    };

    const fids = Array.from({ length: 505 }, (_, i) => `fid-${i}`);
    const stale = await service.notifyDataOnly(fids, {
      title: 'Alice',
      body: 'Encrypted message',
      conversationId: 'c1',
      conversationType: 'direct',
      messageId: 'm1',
      clientMsgId: 'cm1',
      seq: 7,
      senderId: 'alice',
      senderName: 'Alice',
      recipientUserId: 'bob',
      conversationName: '',
      type: 'text',
      createdAt: '2026-11-26T12:00:00.000Z',
      content: 'e2ee:v1:{"v":1}',
    });

    expect(chunkSizes).toEqual([500, 5]);
    expect(stale).toEqual([]);
  });
});
