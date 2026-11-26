import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { createContext } from '../src/http/context.js';
import type { NotificationService, PushPayload } from '../src/lib/fcm.js';
import { createLogger } from '../src/lib/logger.js';
import {
  TEST_CONFIG,
  createDirect,
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
const pushes: { fids: string[]; payload: PushPayload }[] = [];
let staleToReturn: string[] = [];
const fakeNotifications = {
  enabled: true,
  initialize: async () => undefined,
  notify: async (fids: string[], payload: PushPayload) => {
    pushes.push({ fids, payload });
    return staleToReturn;
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

async function seedDevice(user: TestUser, deviceId: string, fcmToken: string): Promise<void> {
  await harness.db.query(
    `INSERT INTO device_tokens (user_id, device_id, fcm_token) VALUES ($1, $2, $3)`,
    [user.id, deviceId, fcmToken],
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

  it('does not push to a recipient with a live socket', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    await seedDevice(bob, 'bob-phone', 'bob-fid');

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
});
