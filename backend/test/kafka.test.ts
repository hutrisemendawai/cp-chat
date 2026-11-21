import { Kafka } from 'kafkajs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { KafkaBroker } from '../src/lib/broker.js';
import { loadConfig, type Config } from '../src/config.js';
import { createLogger } from '../src/lib/logger.js';
import { waitFor, publishUntil, uniqueTopic } from './kafka-helpers.js';

/**
 * Kafka transport against a real broker.
 *
 * These tests are skipped unless `KAFKA_BROKERS` is reachable, so `npm test`
 * stays green without Docker. CI sets it up; see `.github/workflows/ci.yml`.
 */
const brokers = process.env.KAFKA_BROKERS;

function configFor(topic: string): Config {
  return loadConfig({
    NODE_ENV: 'test',
    LOG_LEVEL: 'fatal',
    BROKER: 'kafka',
    KAFKA_BROKERS: brokers ?? 'localhost:9092',
    KAFKA_EVENTS_TOPIC: topic,
    JWT_SECRET: 'test-secret-that-is-long-enough',
  });
}

describe.skipIf(!brokers)('broker (kafka)', () => {
  let topic: string;

  beforeAll(async () => {
    topic = uniqueTopic();
    const admin = new Kafka({
      clientId: 'cp-chat-test-admin',
      brokers: (brokers ?? '').split(','),
    }).admin();
    await admin.connect();
    await admin.createTopics({ topics: [{ topic, numPartitions: 3 }] });
    await admin.disconnect();
  }, 30_000);

  let brokersUnderTest: KafkaBroker[] = [];

  afterAll(async () => {
    for (const broker of brokersUnderTest) await broker.close();
    brokersUnderTest = [];
  });

  it('delivers a frame addressed to another node', async () => {
    const config = configFor(topic);
    const logger = createLogger(config, 'test');
    const nodeA = new KafkaBroker(config, 'node-a', logger);
    const nodeB = new KafkaBroker(config, 'node-b', logger);
    brokersUnderTest.push(nodeA, nodeB);

    const received: Record<string, unknown>[] = [];
    await nodeB.start({
      onRouted: (payload) => received.push(payload as unknown as Record<string, unknown>),
      onBroadcast: () => undefined,
    });

    await nodeA.start();

    await publishUntil(
      () =>
        nodeA.publishToNode('node-b', {
          userId: 'u1',
          frame: { type: 'status', status: 'sent' },
        }),
      () => received.length > 0,
    );
    expect(received[0]).toMatchObject({ userId: 'u1', frame: { type: 'status' } });
  }, 60_000);

  it('delivers a broadcast to a subscriber and keeps per-node addressing', async () => {
    const config = configFor(topic);
    const logger = createLogger(config, 'test');
    const nodeA = new KafkaBroker(config, 'node-a2', logger);
    const nodeB = new KafkaBroker(config, 'node-b2', logger);
    brokersUnderTest.push(nodeA, nodeB);

    const routed: Record<string, unknown>[] = [];
    const broadcasts: Record<string, unknown>[] = [];
    await nodeB.start({
      onRouted: (payload) => routed.push(payload as unknown as Record<string, unknown>),
      onBroadcast: (payload) => broadcasts.push(payload as unknown as Record<string, unknown>),
    });
    await nodeA.start();

    await nodeA.publishBroadcast(
      { user_ids: ['u1', 'u2'], frame: { type: 'presence', online: true } },
      'c:conv-1',
    );
    // Addressed to node-a2, so node-b2 must not see it.
    await nodeA.publishToNode('node-a2', { userId: 'u9', frame: { type: 'status' } });

    await waitFor(() => broadcasts.length === 1);
    expect(broadcasts[0]).toMatchObject({ user_ids: ['u1', 'u2'] });
    expect(routed).toHaveLength(0);
  }, 40_000);

  it('preserves per-conversation order across the partition key', async () => {
    const config = configFor(topic);
    const logger = createLogger(config, 'test');
    const nodeA = new KafkaBroker(config, 'node-a3', logger);
    const nodeB = new KafkaBroker(config, 'node-b3', logger);
    brokersUnderTest.push(nodeA, nodeB);

    const seqs: number[] = [];
    await nodeB.start({
      onRouted: () => undefined,
      onBroadcast: (payload) => {
        const frame = payload.frame as { seq?: number };
        if (typeof frame.seq === 'number') seqs.push(frame.seq);
      },
    });
    await nodeA.start();

    for (let seq = 1; seq <= 10; seq += 1) {
      await nodeA.publishBroadcast(
        { user_ids: ['u1'], frame: { type: 'message', seq } },
        'c:ordered-conversation',
      );
    }

    await waitFor(() => seqs.length === 10);
    expect(seqs).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  }, 40_000);
});
