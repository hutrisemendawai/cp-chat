import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';

import { Kafka } from 'kafkajs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { ChatGateway } from '../src/gateway/chat-gateway.js';
import { NotificationService } from '../src/lib/fcm.js';
import { createContext } from '../src/http/context.js';
import { createLogger } from '../src/lib/logger.js';
import type { Config } from '../src/config.js';
import {
  createDirect,
  registerUser,
  truncateAll,
  type TestHarness,
} from './helpers.js';
import { TEST_CONFIG } from './helpers.js';
import { createHarness } from './helpers.js';
import { uniqueTopic } from './kafka-helpers.js';

/**
 * Async ingest over Kafka: the gateway validates a `send`, writes it to
 * `chat.inbound`, and the consumer group persists it and fans it back out.
 * Skipped unless a broker is reachable (CI configures one).
 */
const brokers = process.env.KAFKA_BROKERS;

let harness: TestHarness;

beforeAll(async () => {
  harness = await createHarness();
});

afterAll(async () => {
  await harness.close();
});

type Gateway = { gateway: ChatGateway; server: Server; port: number; close: () => Promise<void> };

async function startAsyncGateway(config: Config): Promise<Gateway> {
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
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as { port: number }).port;

  return {
    gateway,
    server,
    port,
    close: async () => {
      await gateway.stop();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

function connect(port: number, token: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

function waitForFrame(
  ws: WebSocket,
  match: (frame: Record<string, unknown>) => boolean,
  timeoutMs = 20_000,
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

async function waitForRegistration(userId: string, deviceId: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (await harness.redis.get(`conn:${userId}:${deviceId}`)) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error('socket was never registered');
}

describe.skipIf(!brokers)('gateway async ingest (kafka)', () => {
  it('persists a queued send and delivers it across replicas', async () => {
    const eventsTopic = uniqueTopic();
    const inboundTopic = uniqueTopic();

    const admin = new Kafka({
      clientId: 'cp-chat-test-admin',
      brokers: (brokers ?? '').split(','),
    }).admin();
    await admin.connect();
    await admin.createTopics({
      topics: [
        { topic: eventsTopic, numPartitions: 3 },
        { topic: inboundTopic, numPartitions: 3 },
      ],
    });
    await admin.disconnect();

    const config: Config = {
      ...TEST_CONFIG,
      BROKER: 'kafka',
      KAFKA_BROKERS: brokers ?? 'localhost:9092',
      KAFKA_EVENTS_TOPIC: eventsTopic,
      KAFKA_INBOUND_TOPIC: inboundTopic,
      GATEWAY_ASYNC_INGEST: true,
      gatewayNodeId: 'async-node',
    };

    await truncateAll(harness.db);
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    const replica = await startAsyncGateway(config);
    let aliceSocket: WebSocket | null = null;
    let bobSocket: WebSocket | null = null;

    try {
      aliceSocket = await connect(replica.port, alice.accessToken);
      bobSocket = await connect(replica.port, bob.accessToken);
      await waitForRegistration(alice.id, alice.deviceId);
      await waitForRegistration(bob.id, bob.deviceId);

      const clientMsgId = randomUUID();
      const ack = waitForFrame(
        aliceSocket,
        (frame) => frame.type === 'status' && frame.status === 'sent',
      );
      const delivered = waitForFrame(bobSocket, (frame) => frame.type === 'message');

      aliceSocket.send(
        JSON.stringify({
          type: 'send',
          conversation_id: conversationId,
          client_msg_id: clientMsgId,
          msg_type: 'text',
          content: 'through the log',
        }),
      );

      expect(await ack).toMatchObject({ client_msg_id: clientMsgId, seq: 1, status: 'sent' });
      expect(await delivered).toMatchObject({ client_msg_id: clientMsgId, seq: 1 });

      // The row is durable in Postgres, not only echoed to the sockets.
      const { rows } = await harness.db.query<{ count: string }>(
        `SELECT count(*)::text AS count FROM messages WHERE conversation_id = $1`,
        [conversationId],
      );
      expect(rows[0]!.count).toBe('1');

      // A retried send is idempotent through the consumer as well.
      const retryAck = waitForFrame(
        aliceSocket,
        (frame) => frame.type === 'status' && frame.status === 'sent',
      );
      aliceSocket.send(
        JSON.stringify({
          type: 'send',
          conversation_id: conversationId,
          client_msg_id: clientMsgId,
          msg_type: 'text',
          content: 'through the log',
        }),
      );
      expect((await retryAck).seq).toBe(1);
    } finally {
      aliceSocket?.close();
      bobSocket?.close();
      await replica.close();
    }
  }, 60_000);
});
