import { Kafka, type Consumer, type Producer } from 'kafkajs';

import type { Config } from '../config.js';
import type { Logger } from '../lib/logger.js';
import { withSpan } from '../lib/tracing.js';
import type { AppContext } from '../http/context.js';
import type { MessageRow } from '../domain/messages.js';

/**
 * Inbound message ingestion over Kafka.
 *
 * Phase 1–3 processed a `send` inline on the gateway: validate, allocate `seq`,
 * persist, fan out. That couples gateway latency to database latency and makes
 * a gateway crash mid-send ambiguous. Phase 4 can instead write the accepted
 * send to `chat.inbound` (keyed by conversation, so ordering is preserved) and
 * return the acceptance immediately; this worker consumes the topic and runs
 * the same append + fan-out with consumer-group scaling.
 *
 * `seq` is still allocated by the storage layer, so redelivery of the same
 * `client_msg_id` stays idempotent — at-least-once delivery on the topic is
 * therefore safe.
 */

export type InboundSend = {
  conversation_id: string;
  sender_id: string;
  device_id: string;
  client_msg_id: string;
  msg_type: 'text' | 'image' | 'file';
  content: string;
  accepted_at?: string;
};

export class InboundProducer {
  private producer: Producer | null = null;
  private starting: Promise<void> | null = null;

  constructor(private readonly config: Config) {}

  async publish(send: InboundSend): Promise<void> {
    const producer = await this.ensureProducer();
    await producer.send({
      topic: this.config.KAFKA_INBOUND_TOPIC,
      messages: [{ key: `c:${send.conversation_id}`, value: JSON.stringify(send) }],
    });
  }

  async close(): Promise<void> {
    await this.producer?.disconnect().catch(() => undefined);
    this.producer = null;
  }

  private ensureProducer(): Promise<Producer> {
    if (this.producer) return Promise.resolve(this.producer);
    this.starting ??= (async () => {
      const kafka = new Kafka({
        clientId: `${this.config.KAFKA_CLIENT_ID}-inbound`,
        brokers: this.config.KAFKA_BROKERS.split(',').map((broker) => broker.trim()),
      });
      const producer = kafka.producer({ allowAutoTopicCreation: true });
      await producer.connect();
      this.producer = producer;
    })().catch((error) => {
      this.starting = null;
      throw error;
    });
    return this.starting.then(() => this.producer!);
  }
}

export type InboundOutcome = {
  message: MessageRow;
  duplicate: boolean;
};

/**
 * Consumes `chat.inbound` and persists messages. The group id is shared by all
 * replicas (`KAFKA_INBOUND_GROUP`), so partitions are split between them and
 * one conversation is only ever processed by one replica at a time.
 */
export class InboundConsumer {
  private readonly kafka: Kafka;
  private consumer: Consumer | null = null;

  constructor(
    private readonly config: Config,
    private readonly logger: Logger,
    private readonly onStored: (outcome: InboundOutcome & { send: InboundSend }) => Promise<void>,
  ) {
    this.kafka = new Kafka({
      clientId: `${config.KAFKA_CLIENT_ID}-inbound-consumer`,
      brokers: config.KAFKA_BROKERS.split(',').map((broker) => broker.trim()),
    });
  }

  async start(ctx: AppContext): Promise<void> {
    this.consumer = this.kafka.consumer({ groupId: this.config.KAFKA_INBOUND_GROUP });
    await this.consumer.connect();
    await this.consumer.subscribe({
      topic: this.config.KAFKA_INBOUND_TOPIC,
      fromBeginning: false,
    });

    await this.consumer.run({
      eachMessage: async ({ message }) => {
        const raw = message.value?.toString();
        if (!raw) return;

        let send: InboundSend;
        try {
          send = JSON.parse(raw) as InboundSend;
        } catch (error) {
          this.logger.warn({ err: error }, 'dropped malformed inbound send');
          return;
        }

        try {
          await withSpan(
            'message.ingest',
            { conversation_id: send.conversation_id, sender_id: send.sender_id },
            async () => {
              const outcome = await ctx.messages.append({
                conversationId: send.conversation_id,
                senderId: send.sender_id,
                clientMsgId: send.client_msg_id,
                type: send.msg_type,
                content: send.content,
              });
              await this.onStored({ ...outcome, send });
            },
          );
        } catch (error) {
          // Rethrow so the offset is not committed and the record is retried;
          // append() is idempotent on `client_msg_id`, so a retry is safe.
          this.logger.error({ err: error, conversation: send.conversation_id }, 'inbound ingest failed');
          throw error;
        }
      },
    });

    this.logger.info(
      { topic: this.config.KAFKA_INBOUND_TOPIC, group: this.config.KAFKA_INBOUND_GROUP },
      'inbound consumer started',
    );
  }

  async close(): Promise<void> {
    await this.consumer?.disconnect().catch(() => undefined);
    this.consumer = null;
  }
}
