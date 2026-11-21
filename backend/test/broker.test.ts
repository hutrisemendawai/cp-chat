import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { NotificationService } from '../src/lib/fcm.js';
import { createContext } from '../src/http/context.js';
import { createLogger } from '../src/lib/logger.js';
import { RedisBroker } from '../src/lib/broker.js';
import { TEST_CONFIG, createHarness, registerUser, truncateAll, type TestHarness } from './helpers.js';

let harness: TestHarness;

beforeAll(async () => {
  harness = await createHarness();
});

afterAll(async () => {
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
});

type Harness = {
  gateway: ChatGateway;
  server: Server;
  port: number;
  sockets: WebSocket[];
  connect: (token: string) => Promise<WebSocket>;
  close: () => Promise<void>;
};

function listen(server: Server): Promise<number> {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve((server.address() as { port: number }).port);
    });
  });
}

/**
 * Starts a gateway on its own port. Two of these share one Redis, which is the
 * multi-replica topology Phase 4 has to support.
 */
async function startGateway(nodeId: string): Promise<Harness> {
  const config = { ...TEST_CONFIG, gatewayNodeId: nodeId };
  const ctx = createContext(config, harness.db, harness.redis);
  const logger = createLogger(config, 'test');
  const gateway = new ChatGateway(
    config,
    ctx,
    ctx.broker,
    new NotificationService(config, logger),
    logger,
  );
  await gateway.start();

  const server = createServer();
  server.on('upgrade', (request, socket, head) => gateway.handleUpgrade(request, socket, head));
  const port = await listen(server);
  const sockets: WebSocket[] = [];

  return {
    gateway,
    server,
    port,
    sockets,
    connect: (token: string) =>
      new Promise((resolve, reject) => {
        const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`);
        sockets.push(ws);
        ws.on('open', () => resolve(ws));
        ws.on('error', reject);
      }),
    close: async () => {
      for (const ws of sockets) ws.close();
      await gateway.stop();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

/** Resolves with the first frame for which `match` returns true. */
function waitForFrame(
  ws: WebSocket,
  match: (frame: Record<string, unknown>) => boolean,
  timeoutMs = 4000,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off('message', onMessage);
      reject(new Error('timed out waiting for frame'));
    }, timeoutMs);

    function onMessage(data: WebSocket.RawData) {
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(data.toString()) as Record<string, unknown>;
      } catch {
        return;
      }
      if (!match(frame)) return;
      clearTimeout(timer);
      ws.off('message', onMessage);
      resolve(frame);
    }

    ws.on('message', onMessage);
  });
}

function send(ws: WebSocket, frame: Record<string, unknown>): void {
  ws.send(JSON.stringify(frame));
}

async function waitForRegistration(userId: string, deviceId: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await harness.redis.get(`conn:${userId}:${deviceId}`)) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('socket was never registered');
}

describe('broker (redis)', () => {
  it('round-trips routed and broadcast payloads without an HTTP layer', async () => {
    const broker = new RedisBroker(harness.redis, 'unit-node', createLogger(TEST_CONFIG, 'test'));
    const received: Record<string, unknown>[] = [];

    await broker.start({
      onRouted: (payload) => received.push({ kind: 'routed', ...payload }),
      onBroadcast: (payload) => received.push({ kind: 'broadcast', ...payload }),
    });

    await broker.publishToNode('unit-node', { userId: 'u1', frame: { type: 'status', status: 'sent' } });
    await broker.publishBroadcast({ user_ids: ['u1', 'u2'], frame: { type: 'presence', online: true } });

    for (let attempt = 0; attempt < 100 && received.length < 2; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    expect(received).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: 'routed', userId: 'u1', frame: expect.objectContaining({ type: 'status' }) }),
        expect.objectContaining({
          kind: 'broadcast',
          user_ids: ['u1', 'u2'],
          frame: expect.objectContaining({ type: 'presence' }),
        }),
      ]),
    );

    await broker.close();
  });

  it('uses the stable default transport', async () => {
    expect(TEST_CONFIG.BROKER).toBe('redis');
    expect(harness.app).toBeDefined();
  });
});

describe('gateway scaling', () => {
  it('routes a message between sockets on two different gateway replicas', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const first = await startGateway('replica-a');
    const second = await startGateway('replica-b');

    try {
      const conversation = await harness.app.inject({
        method: 'POST',
        url: '/api/v1/conversations',
        headers: { authorization: `Bearer ${alice.accessToken}` },
        payload: { type: 'direct', member_ids: [bob.id] },
      });
      const conversationId = conversation.json().id;

      // Each member lands on a different node; delivery still crosses over.
      const aliceSocket = await first.connect(alice.accessToken);
      const bobSocket = await second.connect(bob.accessToken);
      await waitForRegistration(alice.id, alice.deviceId);
      await waitForRegistration(bob.id, bob.deviceId);

      const clientMsgId = randomUUID();
      const delivered = waitForFrame(bobSocket, (frame) => frame.type === 'message');
      send(aliceSocket, {
        type: 'send',
        conversation_id: conversationId,
        client_msg_id: clientMsgId,
        msg_type: 'text',
        content: 'across replicas',
      });

      const ack = await waitForFrame(
        aliceSocket,
        (frame) => frame.type === 'status' && frame.status === 'sent',
      );
      expect(ack.seq).toBe(1);
      expect(await delivered).toMatchObject({ client_msg_id: clientMsgId, seq: 1 });
    } finally {
      await first.close();
      await second.close();
    }
  });

  it('reports readiness until a drain begins, then refuses upgrades with 503', async () => {
    const replica = await startGateway('replica-drain');
    const alice = await registerUser(harness, 'Alice');

    try {
      expect(replica.gateway.isReady()).toBe(true);
      const socket = await replica.connect(alice.accessToken);
      await waitForRegistration(alice.id, alice.deviceId);

      const closed = new Promise<number>((resolve) => {
        socket.on('close', (code) => resolve(code));
      });

      const draining = replica.gateway.drain(5000);
      expect(replica.gateway.isReady()).toBe(false);
      expect(replica.gateway.isDraining()).toBe(true);

      // Live clients get 1001 (going away) so they reconnect elsewhere.
      await expect(closed).resolves.toBe(1001);
      await draining;

      // New upgrades are refused while draining.
      const rejected = await new Promise<string>((resolve) => {
        const ws = new WebSocket(
          `ws://127.0.0.1:${replica.port}/ws?token=${encodeURIComponent(alice.accessToken)}`,
        );
        ws.on('unexpected-response', (_request, response) => resolve(String(response.statusCode)));
        ws.on('open', () => resolve('open'));
        ws.on('error', (error) => resolve(error.message));
      });
      expect(rejected).toBe('503');

      // The routing map is cleaned up on close, so peers stop fanning out here.
      expect(await harness.redis.get(`conn:${alice.id}:${alice.deviceId}`)).toBeNull();
    } finally {
      await replica.close();
    }
  });
});
