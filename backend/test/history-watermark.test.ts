import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { createContext } from '../src/http/context.js';
import { MessageRepository } from '../src/domain/messages.js';
import { ScyllaMessageRepository, type ScyllaClient } from '../src/domain/scylla-messages.js';
import type { NotificationService } from '../src/lib/fcm.js';
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
let messages: MessageRepository;
let gateway: ChatGateway;
let server: Server;
let port: number;

const noopNotifications = {
  enabled: false,
  initialize: async () => undefined,
  notify: async () => [],
} as unknown as NotificationService;

beforeAll(async () => {
  harness = await createHarness();
  messages = new MessageRepository(harness.db);
  const ctx = createContext(TEST_CONFIG, harness.db, harness.redis);
  gateway = new ChatGateway(
    TEST_CONFIG,
    ctx,
    ctx.broker,
    noopNotifications,
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
});

function fakeKey(label: string): string {
  return Buffer.from(label.padEnd(32, '.')).toString('base64');
}

async function append(
  conversationId: string,
  sender: TestUser,
  content: string,
): Promise<number> {
  const { message } = await messages.append({
    conversationId,
    senderId: sender.id,
    clientMsgId: randomUUID(),
    type: 'text',
    content,
  });
  return message.seq;
}

async function publishKeys(
  user: TestUser,
  identityLabel: string,
  options: { historyWatermark?: boolean; prekeys?: number } = {},
) {
  const response = await harness.app.inject({
    method: 'POST',
    url: '/api/v1/keys',
    headers: auth(user),
    payload: {
      identity_key: fakeKey(identityLabel),
      signing_key: fakeKey(`sig-${identityLabel}`),
      signed_prekey: {
        key_id: 1,
        public_key: fakeKey(`spk-${identityLabel}`),
        signature: fakeKey(`spksig-${identityLabel}`),
      },
      one_time_prekeys: Array.from({ length: options.prekeys ?? 2 }, (_, i) => ({
        key_id: i + 1,
        public_key: fakeKey(`otp-${identityLabel}-${i}`),
      })),
      ...(options.historyWatermark !== undefined
        ? { history_watermark: options.historyWatermark }
        : {}),
    },
  });
  expect(response.statusCode).toBe(201);
  return response.json();
}

function connectSocket(user: TestUser): Promise<{
  waitFor: (match: (f: Record<string, unknown>) => boolean, timeoutMs?: number) => Promise<Record<string, unknown>>;
  close: () => void;
}> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(user.accessToken)}`,
    );
    const inbox: Record<string, unknown>[] = [];
    const waiters: {
      match: (f: Record<string, unknown>) => boolean;
      resolve: (f: Record<string, unknown>) => void;
      timer: NodeJS.Timeout;
    }[] = [];

    ws.on('message', (data) => {
      const frame = JSON.parse(data.toString()) as Record<string, unknown>;
      const idx = waiters.findIndex((w) => w.match(frame));
      if (idx >= 0) {
        const [waiter] = waiters.splice(idx, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
      } else {
        inbox.push(frame);
      }
    });
    ws.on('error', reject);
    ws.on('open', async () => {
      const start = Date.now();
      while ((await harness.redis.get(`conn:${user.id}:${user.deviceId}`)) === null) {
        if (Date.now() - start > 3000) {
          reject(new Error('socket registration timed out'));
          return;
        }
        await new Promise((r) => setTimeout(r, 20));
      }
      resolve({
        waitFor: (match, timeoutMs = 4000) =>
          new Promise((res, rej) => {
            const idx = inbox.findIndex(match);
            if (idx >= 0) {
              res(inbox.splice(idx, 1)[0]!);
              return;
            }
            const timer = setTimeout(() => {
              const i = waiters.findIndex((w) => w.resolve === res);
              if (i >= 0) waiters.splice(i, 1);
              rej(new Error('timed out waiting for frame'));
            }, timeoutMs);
            waiters.push({ match, resolve: res, timer });
          }),
        close: () => ws.close(),
      });
    });
  });
}

describe('history watermark endpoints', () => {
  it('hides cleared messages from sync, page, search, and list while leaving other members unaffected', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const convId = await createDirect(harness, alice, bob);

    await append(convId, bob, 'secret elephant one');
    await append(convId, alice, 'secret elephant two');
    await append(convId, bob, 'secret elephant three');

    // Alice clears the conversation at seq 3.
    const clearRes = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/clear`,
      headers: auth(alice),
    });
    expect(clearRes.statusCode).toBe(200);
    expect(clearRes.json()).toEqual({ cleared_seq: 3 });

    // Idempotent repeat stays at 3.
    const clearAgain = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/clear`,
      headers: auth(alice),
    });
    expect(clearAgain.json()).toEqual({ cleared_seq: 3 });

    // Sync from 0 returns 0 messages, keeps latest_seq=3, reports cleared_seq=3.
    const syncRes = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(syncRes.statusCode).toBe(200);
    expect(syncRes.json()).toEqual({
      messages: [],
      latest_seq: 3,
      cleared_seq: 3,
    });

    // Page returns empty.
    const pageRes = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/messages`,
      headers: auth(alice),
    });
    expect(pageRes.statusCode).toBe(200);
    expect(pageRes.json()).toEqual({
      messages: [],
      has_more: false,
      cleared_seq: 3,
    });

    // Search (global and in-chat) returns empty for Alice.
    const searchRes = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/search?q=elephant`,
      headers: auth(alice),
    });
    expect(searchRes.json().messages).toHaveLength(0);

    const inChatSearch = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/search?q=elephant`,
      headers: auth(alice),
    });
    expect(inChatSearch.json().messages).toHaveLength(0);

    // Conversation list keeps the row with empty preview, unread 0, cleared_seq 3.
    const listRes = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(alice),
    });
    const aliceConv = listRes.json().conversations[0];
    expect(aliceConv.id).toBe(convId);
    expect(aliceConv.cleared_seq).toBe(3);
    expect(aliceConv.unread_count).toBe(0);
    expect(aliceConv.last_message).toBeNull();
    expect(aliceConv.last_seq).toBe(3);

    // Bob still sees all 3 messages!
    const bobSync = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/sync?after_seq=0`,
      headers: auth(bob),
    });
    expect(bobSync.json().messages).toHaveLength(3);
    expect(bobSync.json().cleared_seq).toBe(0);

    // A new message arrives at seq 4 — Alice sees only seq 4.
    await append(convId, bob, 'fresh elephant four');

    const aliceSyncAfter = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(aliceSyncAfter.json().messages.map((m: { seq: number }) => m.seq)).toEqual([4]);
    expect(aliceSyncAfter.json().latest_seq).toBe(4);
    expect(aliceSyncAfter.json().cleared_seq).toBe(3);

    const alicePageAfter = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${convId}/messages`,
      headers: auth(alice),
    });
    expect(alicePageAfter.json().messages.map((m: { seq: number }) => m.seq)).toEqual([4]);
    expect(alicePageAfter.json().has_more).toBe(false);

    const aliceSearchAfter = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/search?q=elephant',
      headers: auth(alice),
    });
    expect(aliceSearchAfter.json().messages.map((m: { seq: number }) => m.seq)).toEqual([4]);

    const aliceListAfter = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(alice),
    });
    expect(aliceListAfter.json().conversations[0].unread_count).toBe(1);
    expect(aliceListAfter.json().conversations[0].last_message.seq).toBe(4);
  });

  it('rejects non-members clearing a conversation', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const convId = await createDirect(harness, alice, bob);

    const res = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${convId}/clear`,
      headers: auth(carol),
    });
    expect(res.statusCode).toBe(403);
  });

  it('clears all conversations (direct and group) via POST /users/me/history/clear and broadcasts history_cleared', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const directId = await createDirect(harness, alice, bob);
    const groupId = await createGroup(harness, alice, [bob], 'Squad');

    await append(directId, bob, 'direct hello');
    await append(directId, bob, 'direct two');
    await append(groupId, bob, 'group hello');

    const socket = await connectSocket(alice);
    try {
      const clearAll = await harness.app.inject({
        method: 'POST',
        url: '/api/v1/users/me/history/clear',
        headers: auth(alice),
      });
      expect(clearAll.statusCode).toBe(200);
      expect(clearAll.json().conversations).toBe(2);
      expect(typeof clearAll.json().cleared_at).toBe('string');

      const f1 = await socket.waitFor(
        (f) => f.type === 'history_cleared' && f.conversation_id === directId,
      );
      expect(f1.cleared_seq).toBe(2);

      const f2 = await socket.waitFor(
        (f) => f.type === 'history_cleared' && f.conversation_id === groupId,
      );
      expect(f2.cleared_seq).toBe(1);

      // Both conversations now sync empty from 0.
      const dSync = await harness.app.inject({
        method: 'GET',
        url: `/api/v1/conversations/${directId}/sync?after_seq=0`,
        headers: auth(alice),
      });
      expect(dSync.json().messages).toEqual([]);
      expect(dSync.json().cleared_seq).toBe(2);

      const gSync = await harness.app.inject({
        method: 'GET',
        url: `/api/v1/conversations/${groupId}/sync?after_seq=0`,
        headers: auth(alice),
      });
      expect(gSync.json().messages).toEqual([]);
      expect(gSync.json().cleared_seq).toBe(1);
    } finally {
      socket.close();
    }
  });
});

describe('key-epoch rotation watermark', () => {
  it('increments key_epoch and advances direct-chat watermarks on identity rotation when history_watermark=true, leaving groups untouched', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const directId = await createDirect(harness, alice, bob);
    const groupId = await createGroup(harness, alice, [bob], 'Plaintext Group');

    await append(directId, bob, 'old-cipher-1');
    await append(directId, bob, 'old-cipher-2');
    await append(groupId, bob, 'group-plain-1');

    // First-ever publish: key_epoch = 1, clears nothing.
    const first = await publishKeys(alice, 'id-v1', { historyWatermark: true });
    expect(first.key_epoch).toBe(1);
    expect(first.rotated).toBe(false);

    const me1 = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/keys/me',
      headers: auth(alice),
    });
    expect(me1.json().key_epoch).toBe(1);
    const rotatedAt1 = me1.json().rotated_at;
    expect(typeof rotatedAt1).toBe('string');

    // Direct chat is NOT cleared on first publish.
    const syncBefore = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${directId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(syncBefore.json().cleared_seq).toBe(0);
    expect(syncBefore.json().messages).toHaveLength(2);

    // Same-identity republish: key_epoch stays 1, clears nothing.
    const republish = await publishKeys(alice, 'id-v1', { historyWatermark: true });
    expect(republish.key_epoch).toBe(1);
    expect(republish.rotated).toBe(false);

    const syncAfterRepublish = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${directId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(syncAfterRepublish.json().cleared_seq).toBe(0);

    // Identity rotation WITHOUT history_watermark flag: key_epoch -> 2, does NOT auto-clear.
    const rotNoFlag = await publishKeys(alice, 'id-v2', { historyWatermark: false });
    expect(rotNoFlag.key_epoch).toBe(2);
    expect(rotNoFlag.rotated).toBe(true);

    const syncAfterNoFlag = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${directId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(syncAfterNoFlag.json().cleared_seq).toBe(0);

    // Identity rotation WITH history_watermark: true -> key_epoch -> 3, direct cleared to 2, group untouched (0).
    const rotWithFlag = await publishKeys(alice, 'id-v3', { historyWatermark: true });
    expect(rotWithFlag.key_epoch).toBe(3);
    expect(rotWithFlag.rotated).toBe(true);

    const me3 = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/keys/me',
      headers: auth(alice),
    });
    expect(me3.json().key_epoch).toBe(3);
    expect(me3.json().identity_key).toBe(fakeKey('id-v3'));

    const directSync = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${directId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(directSync.json().cleared_seq).toBe(2);
    expect(directSync.json().messages).toEqual([]);

    const groupSync = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}/sync?after_seq=0`,
      headers: auth(alice),
    });
    expect(groupSync.json().cleared_seq).toBe(0);
    expect(groupSync.json().messages).toHaveLength(1);
  });
});

describe('scylla message repository watermark lower bound (unit)', () => {
  it('passes clearedSeq lower bound in CQL page queries', async () => {
    const executed: { query: string; params: unknown[] }[] = [];
    const fakeClient: ScyllaClient = {
      execute: async (query, params = []) => {
        executed.push({ query, params });
        return { rows: [] };
      },
      shutdown: async () => undefined,
    };
    const repo = new ScyllaMessageRepository(fakeClient, createLogger(TEST_CONFIG, 'test'));

    await repo.page('conv-1', 20, undefined, 5);
    expect(executed[0]!.query).toContain('seq > ?');
    expect(executed[0]!.params).toEqual(['conv-1', 5, 21]);

    await repo.page('conv-1', 20, 15, 5);
    expect(executed[1]!.query).toContain('seq < ? AND seq > ?');
    expect(executed[1]!.params).toEqual(['conv-1', 15, 5, 21]);
  });
});
