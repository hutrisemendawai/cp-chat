import { Kafka, type Consumer, type Producer } from 'kafkajs';

import type { Config } from '../config.js';
import type { Logger } from './logger.js';
import { redisKeys, type Cache } from './redis.js';

/**
 * Inter-service delivery for realtime frames.
 *
 * The gateway needs two shapes of fan-out:
 * - `routed`: one user (optionally one device), delivered by the node that
 *   holds that user's socket;
 * - `broadcast`: a set of users, potentially spread over every node.
 *
 * Redis Pub/Sub is the Phase 1–3 transport. Phase 4 adds Kafka, which makes the
 * stream durable, replayable and partitioned. Frames are keyed by the
 * conversation (falling back to the user id), so every event for one chat lands
 * on the same partition and a consumer sees them in order.
 */

export type RoutedPayload = {
  userId: string;
  frame: Record<string, unknown>;
  /** Skip this device (the originating socket). */
  excludeDevice?: string;
  /** Deliver only to this device, e.g. the `sent` ack for a queued send. */
  onlyDevice?: string;
};

export type BroadcastPayload = {
  user_ids: string[];
  frame: Record<string, unknown>;
};

export type BrokerHandlers = {
  onRouted: (payload: RoutedPayload) => void;
  onBroadcast: (payload: BroadcastPayload) => void;
};

export type BrokerKind = 'redis' | 'kafka';

export interface Broker {
  readonly kind: BrokerKind;
  /** Connects producers and, when handlers are supplied, starts consuming. */
  start(handlers?: BrokerHandlers): Promise<void>;
  publishToNode(nodeId: string, payload: RoutedPayload, key?: string): Promise<void>;
  publishBroadcast(payload: BroadcastPayload, key?: string): Promise<void>;
  close(): Promise<void>;
}

/** Redis Pub/Sub transport. Unchanged from Phase 1–3 on the wire. */
export class RedisBroker implements Broker {
  readonly kind = 'redis' as const;
  private subscriber: Cache | null = null;

  constructor(
    private readonly redis: Cache,
    private readonly nodeId: string,
    private readonly logger: Logger,
  ) {}

  async start(handlers?: BrokerHandlers): Promise<void> {
    if (!handlers) return;

    this.subscriber = this.redis.duplicate();
    await this.subscriber.subscribe(
      redisKeys.channelForNode(this.nodeId),
      redisKeys.allNodesChannel,
    );
    this.subscriber.on('message', (channel, raw) => {
      try {
        if (channel === redisKeys.allNodesChannel) {
          handlers.onBroadcast(JSON.parse(raw) as BroadcastPayload);
          return;
        }
        handlers.onRouted(JSON.parse(raw) as RoutedPayload);
      } catch (error) {
        this.logger.debug({ err: error }, 'dropped malformed broker payload');
      }
    });
  }

  async publishToNode(nodeId: string, payload: RoutedPayload): Promise<void> {
    await this.redis.publish(redisKeys.channelForNode(nodeId), JSON.stringify(payload));
  }

  async publishBroadcast(payload: BroadcastPayload): Promise<void> {
    if (payload.user_ids.length === 0) return;
    await this.redis.publish(redisKeys.allNodesChannel, JSON.stringify(payload));
  }

  async close(): Promise<void> {
    await this.subscriber?.quit();
    this.subscriber = null;
  }
}

type KafkaEnvelope =
  | ({ kind: 'routed' } & RoutedPayload)
  | ({ kind: 'broadcast' } & BroadcastPayload);

/**
 * Kafka transport.
 *
 * One topic carries every realtime frame. Each gateway replica joins its own
 * consumer group (`gateway-<node_id>`), so every replica reads every partition
 * and can deliver to the sockets it owns. A *shared* group would split
 * partitions across replicas and drop frames whose recipient lives on a
 * different node, so it must not be used here.
 *
 * `publishToNode` targets one node by encoding the target in the envelope; the
 * other consumers skip it, which keeps the redundant work to a single check.
 */
export class KafkaBroker implements Broker {
  readonly kind = 'kafka' as const;
  private readonly kafka: Kafka;
  private producer: Producer | null = null;
  private consumer: Consumer | null = null;
  private starting: Promise<void> | null = null;

  constructor(
    private readonly config: Config,
    private readonly nodeId: string,
    private readonly logger: Logger,
  ) {
    this.kafka = new Kafka({
      clientId: `${config.KAFKA_CLIENT_ID}-${nodeId}`,
      brokers: config.KAFKA_BROKERS.split(',').map((broker) => broker.trim()).filter(Boolean),
      retry: { retries: 8 },
    });
  }

  async start(handlers?: BrokerHandlers): Promise<void> {
    await this.ensureProducer();
    if (!handlers) return;

    this.consumer = this.kafka.consumer({
      groupId: `${this.config.KAFKA_CONSUMER_PREFIX}-${this.nodeId}`,
      // A single long-lived gateway wants the whole stream, not a per-tick
      // rebalance, so it consumes without joining a shared group.
      sessionTimeout: 30_000,
    });
    await this.consumer.connect();
    await this.consumer.subscribe({
      topic: this.config.KAFKA_EVENTS_TOPIC,
      fromBeginning: false,
    });

    // `run()` resolves once the consumer loop has started, but the group join
    // and partition assignment land asynchronously after it. A publish that
    // races the join is still delivered, but only after the rebalance, which
    // shows up as an unexpectedly large first-message latency. Wait for the
    // first assignment so a caller can treat `start()` as "ready to receive".
    //
    // The listener must be registered *before* `run()`: kafkajs emits
    // GROUP_JOIN during the join attempt, which `run()` schedules immediately,
    // so attaching it afterwards misses the event on a single-member group.
    const assigned = new Promise<void>((resolve) => {
      const timeout = setTimeout(resolve, 10_000);
      timeout.unref?.();
      this.consumer!.on(this.consumer!.events.GROUP_JOIN, () => {
        clearTimeout(timeout);
        // Resolve on a later tick so the fetch loop has begun.
        setImmediate(resolve);
      });
    });

    await this.consumer.run({
      eachMessage: async ({ message }) => {
        const raw = message.value?.toString();
        if (!raw) return;
        try {
          const envelope = JSON.parse(raw) as KafkaEnvelope & { targetNode?: string };
          if (envelope.kind === 'broadcast') {
            handlers.onBroadcast({ user_ids: envelope.user_ids, frame: envelope.frame });
            return;
          }
          if (envelope.targetNode && envelope.targetNode !== this.nodeId) return;
          handlers.onRouted({
            userId: envelope.userId,
            frame: envelope.frame,
            excludeDevice: envelope.excludeDevice,
            onlyDevice: envelope.onlyDevice,
          });
        } catch (error) {
          this.logger.debug({ err: error }, 'dropped malformed kafka frame');
        }
      },
    });

    await assigned;
    this.logger.info(
      { topic: this.config.KAFKA_EVENTS_TOPIC, group: `${this.config.KAFKA_CONSUMER_PREFIX}-${this.nodeId}` },
      'kafka broker consuming',
    );
  }

  async publishToNode(nodeId: string, payload: RoutedPayload, key?: string): Promise<void> {
    await this.publish(
      { kind: 'routed', targetNode: nodeId, ...payload } as KafkaEnvelope,
      key ?? payload.userId,
    );
  }

  async publishBroadcast(payload: BroadcastPayload, key?: string): Promise<void> {
    if (payload.user_ids.length === 0) return;
    await this.publish({ kind: 'broadcast', ...payload } as KafkaEnvelope, key ?? 'broadcast');
  }

  async close(): Promise<void> {
    await this.consumer?.disconnect().catch(() => undefined);
    await this.producer?.disconnect().catch(() => undefined);
    this.consumer = null;
    this.producer = null;
  }

  private async publish(envelope: KafkaEnvelope, key: string): Promise<void> {
    await this.ensureProducer();
    await this.producer!.send({
      topic: this.config.KAFKA_EVENTS_TOPIC,
      // The key selects the partition, which preserves per-conversation order.
      messages: [{ key, value: JSON.stringify(envelope) }],
    });
  }

  private ensureProducer(): Promise<void> {
    if (this.producer) return Promise.resolve();
    this.starting ??= (async () => {
      const producer = this.kafka.producer({ allowAutoTopicCreation: true });
      await producer.connect();
      this.producer = producer;
    })().catch((error) => {
      this.starting = null;
      throw error;
    });
    return this.starting;
  }
}

export function createBroker(
  config: Config,
  redis: Cache,
  nodeId: string,
  logger: Logger,
): Broker {
  return config.BROKER === 'kafka'
    ? new KafkaBroker(config, nodeId, logger)
    : new RedisBroker(redis, nodeId, logger);
}
