import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { createContext } from '../src/http/context.js';
import type { NotificationService } from '../src/lib/fcm.js';
import type { PushPayload } from '../src/lib/fcm.js';
import { createLogger } from '../src/lib/logger.js';
import {
  TEST_CONFIG,
  auth,
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

/** Records pushes instead of talking to Firebase, so DND suppression is observable. */
const pushes: { fids: string[]; payload: PushPayload }[] = [];
const fakeNotifications = {
  enabled: true,
  initialize: async () => undefined,
  notify: async (fids: string[], payload: PushPayload) => {
    pushes.push({ fids, payload });
    return [];
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
});

type TestSocket = {
  send: (frame: unknown) => void;
  wait: (
    match: (frame: Record<string, unknown>) => boolean,
    timeoutMs?: number,
  ) => Promise<Record<string, unknown>>;
  close: () => void;
};

async function waitForRegistration(user: TestUser): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await harness.redis.get(`conn:${user.id}:${user.deviceId}`)) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('socket was never registered');
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

async function setStatus(userId: string, status: string): Promise<void> {
  await harness.db.query(`UPDATE users SET status = $2 WHERE id = $1`, [userId, status]);
}

describe('presence frames', () => {
  it('broadcasts the preferred status when a user connects', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await setStatus(alice.id, 'idle');

    const bobSocket = await connect(bob);
    const aliceSocket = await connect(alice);

    const frame = await bobSocket.wait(
      (item) => item.type === 'presence' && item.user_id === alice.id,
    );
    expect(frame).toMatchObject({ online: true, status: 'idle', custom_status: null });

    aliceSocket.close();
    bobSocket.close();
  });

  it('never broadcast an invisible user as online', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await setStatus(alice.id, 'invisible');

    const bobSocket = await connect(bob);
    // Bob must not see Alice flip to online.
    await expect(
      bobSocket.wait(
        (item) => item.type === 'presence' && item.user_id === alice.id && item.online === true,
        400,
      ),
    ).rejects.toThrow('timed out');

    const aliceSocket = await connect(alice);

    const frame = await bobSocket.wait(
      (item) => item.type === 'presence' && item.user_id === alice.id,
    );
    expect(frame).toMatchObject({ online: false, status: 'offline' });

    aliceSocket.close();
    bobSocket.close();
  });

  it('accepts a presence update over the socket and fans it to peers', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);

    const bobSocket = await connect(bob);
    const aliceSocket = await connect(alice);
    await bobSocket.wait((item) => item.type === 'presence' && item.user_id === alice.id);

    aliceSocket.send({ type: 'presence', status: 'dnd', custom_status: 'focus mode' });

    const frame = await bobSocket.wait(
      (item) =>
        item.type === 'presence' &&
        item.user_id === alice.id &&
        item.status === 'dnd',
    );
    expect(frame).toMatchObject({ online: true, status: 'dnd', custom_status: 'focus mode' });

    aliceSocket.close();
    bobSocket.close();
  });

  it('rejects an invalid status sent over the socket', async () => {
    const alice = await registerUser(harness, 'Alice');
    const socket = await connect(alice);

    socket.send({ type: 'presence', status: 'away' });

    const error = await socket.wait((item) => item.type === 'error');
    expect(error.code).toBe('validation_error');

    socket.close();
  });
});

describe('dnd notification suppression', () => {
  it('suppresses the push for an offline dnd recipient but still delivers to a normal one', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const bobGroup = await createDirect(harness, alice, bob);
    const carolGroup = await createDirect(harness, alice, carol);
    void bobGroup;
    void carolGroup;

    // Both recipients are offline with a registered device.
    await harness.db.query(
      `INSERT INTO device_tokens (user_id, device_id, fcm_token)
       VALUES ($1, 'bob-phone', 'bob-fid'), ($2, 'carol-phone', 'carol-fid')`,
      [bob.id, carol.id],
    );
    await setStatus(bob.id, 'dnd');
    await setStatus(carol.id, 'online');

    const aliceSocket = await connect(alice);

    aliceSocket.send({
      type: 'send',
      conversation_id: bobGroup,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'hello bob',
    });
    await aliceSocket.wait((item) => item.type === 'status' && item.status === 'sent');

    aliceSocket.send({
      type: 'send',
      conversation_id: carolGroup,
      client_msg_id: randomUUID(),
      msg_type: 'text',
      content: 'hello carol',
    });
    await aliceSocket.wait(
      (item) => item.type === 'status' && item.status === 'sent' && item.conversation_id === carolGroup,
    );

    // Give the fan-out's fire-and-forget notify a tick to settle.
    await new Promise((resolve) => setTimeout(resolve, 200));

    const recipients = pushes.map((push) => push.fids[0]);
    expect(recipients).toContain('carol-fid');
    expect(recipients).not.toContain('bob-fid');

    aliceSocket.close();
  });
});

describe('profile presence in REST', () => {
  it('reflects a socket-driven status update in the REST profile', async () => {
    const alice = await registerUser(harness, 'Alice');
    const socket = await connect(alice);

    socket.send({ type: 'presence', status: 'idle', custom_status: 'brb' });
    // Presence updates are fire-and-forget; poll for the write to land.
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const { rows } = await harness.db.query<{ status: string }>(
        `SELECT status FROM users WHERE id = $1`,
        [alice.id],
      );
      if (rows[0]?.status === 'idle') break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/me',
      headers: auth(alice),
    });
    expect(response.json()).toMatchObject({
      status: 'idle',
      effective_status: 'idle',
      custom_status: 'brb',
    });

    socket.close();
  });
});
