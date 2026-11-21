import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { loadConfig } from '../src/config.js';
import { MessageRepository } from '../src/domain/messages.js';
import { createScyllaClient, ScyllaMessageRepository } from '../src/domain/scylla-messages.js';
import { createLogger } from '../src/lib/logger.js';
import { TEST_CONFIG, createDirect, createHarness, registerUser, truncateAll, type TestHarness, type TestUser } from './helpers.js';

/**
 * The wide-column path must be a drop-in replacement for the Postgres read
 * path. These tests enable it explicitly and assert the results match, so a
 * regression in pagination direction, cursor exclusivity, or `has_more` shows
 * up here rather than in production.
 *
 * Skipped unless `SCYLLA_TEST=1` (CI / local Docker run this).
 */
const enabled = process.env.SCYLLA_TEST === '1';

let harness: TestHarness;
let postgres: MessageRepository;
let wideColumn: MessageRepository;
let scylla: ScyllaMessageRepository;

const baseConfig = loadConfig({
  NODE_ENV: 'test',
  LOG_LEVEL: 'fatal',
  MESSAGE_STORE: 'scylla',
  SCYLLA_CONTACT_POINTS: process.env.SCYLLA_CONTACT_POINTS ?? 'localhost:9042',
  SCYLLA_KEYSPACE: process.env.SCYLLA_KEYSPACE ?? 'cp_chat',
  SCYLLA_LOCAL_DATACENTER: process.env.SCYLLA_LOCAL_DATACENTER ?? 'datacenter1',
});

beforeAll(async () => {
  if (!enabled) return;
  harness = await createHarness();
  postgres = new MessageRepository(harness.db);
  scylla = new ScyllaMessageRepository(
    createScyllaClient(baseConfig),
    createLogger(TEST_CONFIG, 'test'),
  );
  wideColumn = new MessageRepository(harness.db, { scylla });
});

afterAll(async () => {
  if (!enabled) return;
  await scylla.close();
  await harness.close();
});

beforeEach(async () => {
  if (!enabled) return;
  await truncateAll(harness.db);
});

async function send(
  repository: MessageRepository,
  sender: TestUser,
  conversationId: string,
  content: string,
): Promise<number> {
  const { message } = await repository.append({
    conversationId,
    senderId: sender.id,
    clientMsgId: randomUUID(),
    type: 'text',
    content,
  });
  return message.seq;
}

describe.skipIf(!enabled)('scylla message store', () => {
  it('dual-writes so history reads match the Postgres path exactly', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    for (let index = 1; index <= 12; index += 1) {
      await send(wideColumn, alice, conversationId, `message ${index}`);
    }

    const pgPage = await postgres.page(conversationId, 5);
    const scPage = await wideColumn.page(conversationId, 5);
    expect(scPage.messages.map((m) => m.seq)).toEqual(pgPage.messages.map((m) => m.seq));
    expect(scPage.messages.map((m) => m.content)).toEqual(pgPage.messages.map((m) => m.content));
    expect(scPage.hasMore).toBe(pgPage.hasMore);

    const pgNext = await postgres.page(conversationId, 5, pgPage.messages.at(-1)!.seq);
    const scNext = await wideColumn.page(conversationId, 5, scPage.messages.at(-1)!.seq);
    expect(scNext.messages.map((m) => m.seq)).toEqual(pgNext.messages.map((m) => m.seq));

    // Ascending catch-up from a cursor.
    const pgSync = await postgres.sync(conversationId, 4, 100);
    const scSync = await wideColumn.sync(conversationId, 4, 100);
    expect(scSync.messages.map((m) => m.seq)).toEqual(pgSync.messages.map((m) => m.seq));
    expect(scSync.latestSeq).toBe(12);
    expect(scSync.hasMore).toBe(false);
  });

  it('finds one message by seq and by client_msg_id', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    const clientMsgId = randomUUID();

    const { message } = await wideColumn.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'lookup me',
    });

    expect(await scylla.findBySeq(conversationId, message.seq)).toMatchObject({
      id: message.id,
      content: 'lookup me',
    });
    expect(await scylla.findByClientId(alice.id, clientMsgId)).toMatchObject({
      conversation_id: conversationId,
      seq: message.seq,
    });
    expect(await scylla.findBySeq(conversationId, 999)).toBeNull();
  });

  it('keeps seq allocation idempotent across a retried client_msg_id', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    const clientMsgId = randomUUID();

    const first = await wideColumn.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'once',
    });
    const retry = await wideColumn.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'once',
    });

    expect(retry.duplicate).toBe(true);
    expect(retry.message.seq).toBe(first.message.seq);

    const page = await wideColumn.page(conversationId, 10);
    expect(page.messages).toHaveLength(1);
  });

  it('keeps receipt and read-cursor paths on Postgres while serving history from Scylla', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    await send(wideColumn, alice, conversationId, 'read me');
    const message = await wideColumn.findBySeq(conversationId, 1);
    expect(message).not.toBeNull();

    const readSeq = await wideColumn.markRead(conversationId, bob.id, 1);
    expect(readSeq).toBe(1);

    const delivered = await wideColumn.markDeliveredBySeq(conversationId, 1, bob.id);
    expect(delivered?.id).toBe(message!.id);

    // Full-text search still runs on Postgres and sees the dual-written row.
    const results = await wideColumn.search({
      userId: bob.id,
      query: 'read',
      conversationId,
      limit: 10,
    });
    expect(results.messages).toHaveLength(1);
  });

  it('reports has_more only when the page is truncated', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    for (let index = 1; index <= 3; index += 1) {
      await send(wideColumn, alice, conversationId, `m${index}`);
    }

    const exact = await wideColumn.page(conversationId, 3);
    expect(exact.messages).toHaveLength(3);
    expect(exact.hasMore).toBe(false);

    const truncated = await wideColumn.page(conversationId, 2);
    expect(truncated.messages).toHaveLength(2);
    expect(truncated.hasMore).toBe(true);
  });
});
