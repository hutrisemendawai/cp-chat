import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { MessageRepository } from '../src/domain/messages.js';
import {
  auth,
  createDirect,
  createHarness,
  registerUser,
  truncateAll,
  type TestHarness,
} from './helpers.js';

let harness: TestHarness;
let messages: MessageRepository;

beforeAll(async () => {
  harness = await createHarness();
  messages = new MessageRepository(harness.db);
});

afterAll(async () => {
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
});

describe('seq allocation', () => {
  it('starts at 1 and increments without gaps', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    const seqs: number[] = [];
    for (let index = 0; index < 5; index += 1) {
      const stored = await messages.append({
        conversationId,
        senderId: alice.id,
        clientMsgId: randomUUID(),
        type: 'text',
        content: `message ${index}`,
      });
      seqs.push(stored.message.seq);
    }

    expect(seqs).toEqual([1, 2, 3, 4, 5]);
  });

  it('does not consume a seq when the same client_msg_id is retried', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    const clientMsgId = randomUUID();

    const first = await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'only once',
    });
    const retry = await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'only once',
    });
    const next = await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId: randomUUID(),
      type: 'text',
      content: 'next',
    });

    expect(first.duplicate).toBe(false);
    expect(retry.duplicate).toBe(true);
    expect(retry.message.id).toBe(first.message.id);
    expect(retry.message.seq).toBe(1);
    expect(next.message.seq).toBe(2);
  });

  it('serializes concurrent sends into a contiguous sequence', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    const results = await Promise.all(
      Array.from({ length: 20 }, (_, index) =>
        messages.append({
          conversationId,
          senderId: index % 2 === 0 ? alice.id : bob.id,
          clientMsgId: randomUUID(),
          type: 'text',
          content: `concurrent ${index}`,
        }),
      ),
    );

    const seqs = results.map((result) => result.message.seq).sort((a, b) => a - b);
    expect(seqs).toEqual(Array.from({ length: 20 }, (_, index) => index + 1));
  });

  it('keeps the same client_msg_id from different senders independent', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    const clientMsgId = randomUUID();

    const fromAlice = await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId,
      type: 'text',
      content: 'from alice',
    });
    const fromBob = await messages.append({
      conversationId,
      senderId: bob.id,
      clientMsgId,
      type: 'text',
      content: 'from bob',
    });

    expect(fromAlice.duplicate).toBe(false);
    expect(fromBob.duplicate).toBe(false);
    expect(fromAlice.message.seq).not.toBe(fromBob.message.seq);
  });
});

describe('history and sync', () => {
  async function seed(count: number) {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    for (let index = 0; index < count; index += 1) {
      await messages.append({
        conversationId,
        senderId: index % 2 === 0 ? alice.id : bob.id,
        clientMsgId: randomUUID(),
        type: 'text',
        content: `message ${index + 1}`,
      });
    }
    return { alice, bob, conversationId };
  }

  it('returns newest first with an exclusive cursor', async () => {
    const { conversationId } = await seed(10);

    const firstPage = await messages.page(conversationId, 4);
    const secondPage = await messages.page(conversationId, 4, 7);

    expect(firstPage.messages.map((message) => message.seq)).toEqual([10, 9, 8, 7]);
    expect(firstPage.hasMore).toBe(true);
    expect(secondPage.messages.map((message) => message.seq)).toEqual([6, 5, 4, 3]);
    expect(secondPage.hasMore).toBe(true);
  });

  it('reports has_more false on the final page', async () => {
    const { conversationId } = await seed(3);

    const page = await messages.page(conversationId, 10);
    expect(page.messages).toHaveLength(3);
    expect(page.hasMore).toBe(false);
  });

  it('syncs ascending after a cursor and reports the latest seq', async () => {
    const { conversationId } = await seed(5);

    const result = await messages.sync(conversationId, 2, 200);
    expect(result.messages.map((message) => message.seq)).toEqual([3, 4, 5]);
    expect(result.latestSeq).toBe(5);
  });

  it('syncs nothing when the cursor is current', async () => {
    const { conversationId } = await seed(3);

    const result = await messages.sync(conversationId, 3, 200);
    expect(result.messages).toEqual([]);
    expect(result.latestSeq).toBe(3);
  });
});

describe('delivery and read cursors', () => {
  it('records a delivered receipt idempotently', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    const stored = await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId: randomUUID(),
      type: 'text',
      content: 'hi',
    });

    const first = await messages.markDeliveredBySeq(conversationId, stored.message.seq, bob.id);
    const second = await messages.markDeliveredBySeq(conversationId, stored.message.seq, bob.id);

    expect(first?.id).toBe(stored.message.id);
    expect(second?.id).toBe(stored.message.id);

    const { rows } = await harness.db.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM message_receipts WHERE message_id = $1`,
      [stored.message.id],
    );
    expect(rows[0]!.count).toBe('1');
  });

  it('never moves the read cursor backwards', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    expect(await messages.markRead(conversationId, bob.id, 5)).toBe(5);
    expect(await messages.markRead(conversationId, bob.id, 3)).toBe(5);
    expect(await messages.markRead(conversationId, bob.id, 9)).toBe(9);
  });

  it('rejects a read cursor for a non-member', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const conversationId = await createDirect(harness, alice, bob);

    await expect(messages.markRead(conversationId, eve.id, 1)).rejects.toMatchObject({
      code: 'not_a_member',
    });
  });
});

describe('message REST endpoints', () => {
  it('returns unread counts from the member read cursor', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    for (let index = 0; index < 3; index += 1) {
      await messages.append({
        conversationId,
        senderId: alice.id,
        clientMsgId: randomUUID(),
        type: 'text',
        content: `unread ${index}`,
      });
    }

    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(bob),
    });
    const entry = list
      .json()
      .conversations.find((conversation: { id: string }) => conversation.id === conversationId);

    expect(entry.unread_count).toBe(3);
    expect(entry.last_message.seq).toBe(3);

    await messages.markRead(conversationId, bob.id, 3);

    const afterRead = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(bob),
    });
    const updated = afterRead
      .json()
      .conversations.find((conversation: { id: string }) => conversation.id === conversationId);
    expect(updated.unread_count).toBe(0);
  });

  it('does not count the caller own messages as unread', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    await messages.append({
      conversationId,
      senderId: alice.id,
      clientMsgId: randomUUID(),
      type: 'text',
      content: 'mine',
    });

    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(alice),
    });
    const entry = list
      .json()
      .conversations.find((conversation: { id: string }) => conversation.id === conversationId);

    expect(entry.unread_count).toBe(0);
  });

  it('paginates through the messages endpoint', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    for (let index = 0; index < 6; index += 1) {
      await messages.append({
        conversationId,
        senderId: alice.id,
        clientMsgId: randomUUID(),
        type: 'text',
        content: `page ${index}`,
      });
    }

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/messages?before_seq=5&limit=2`,
      headers: auth(bob),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().messages.map((message: { seq: number }) => message.seq)).toEqual([4, 3]);
    expect(response.json().has_more).toBe(true);
  });

  it('validates sync query parameters', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    const negative = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/sync?after_seq=-1`,
      headers: auth(bob),
    });
    const tooLarge = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/sync?limit=1000`,
      headers: auth(bob),
    });

    expect(negative.statusCode).toBe(422);
    expect(tooLarge.statusCode).toBe(422);
  });

  it('forbids non-members from paging or syncing', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const conversationId = await createDirect(harness, alice, bob);

    const page = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/messages`,
      headers: auth(eve),
    });
    const sync = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/sync?after_seq=0`,
      headers: auth(eve),
    });

    expect(page.statusCode).toBe(403);
    expect(sync.statusCode).toBe(403);
  });
});
