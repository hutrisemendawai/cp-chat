import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { PresenceService } from '../src/domain/presence.js';
import { MessageRepository } from '../src/domain/messages.js';
import {
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
let presence: PresenceService;

beforeAll(async () => {
  harness = await createHarness();
  messages = new MessageRepository(harness.db);
  presence = new PresenceService(harness.redis, harness.db, 45);
});

afterAll(async () => {
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
});

async function send(
  sender: TestUser,
  conversationId: string,
  content: string,
): Promise<void> {
  await messages.append({
    conversationId,
    senderId: sender.id,
    clientMsgId: randomUUID(),
    type: 'text',
    content,
  });
}

describe('presence', () => {
  it('reports offline with no last seen for a fresh user', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/presence/${alice.id}`,
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      user_id: alice.id,
      online: false,
      status: 'offline',
      custom_status: null,
      last_seen_at: null,
    });
  });

  it('tracks the online key with a TTL and reflects it in the snapshot', async () => {
    const alice = await registerUser(harness, 'Alice');
    await presence.touch(alice.id);

    const ttl = await harness.redis.ttl(`presence:${alice.id}`);
    expect(ttl).toBeGreaterThan(0);
    expect(ttl).toBeLessThanOrEqual(45);

    const snapshot = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/presence/${alice.id}`,
      headers: auth(alice),
    });
    expect(snapshot.json().online).toBe(true);
  });

  it('records a durable last-seen timestamp when marking a user offline', async () => {
    const alice = await registerUser(harness, 'Alice');
    await presence.touch(alice.id);

    const lastSeen = await presence.markOffline(alice.id);

    expect(await presence.isOnline(alice.id)).toBe(false);
    const { rows } = await harness.db.query<{ last_seen_at: Date }>(
      `SELECT last_seen_at FROM users WHERE id = $1`,
      [alice.id],
    );
    expect(rows[0]!.last_seen_at).not.toBeNull();
    expect(rows[0]!.last_seen_at.getTime()).toBe(lastSeen.getTime());
  });

  it('finds every distinct peer who shares a conversation', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const dave = await registerUser(harness, 'Dave');

    await createDirect(harness, alice, bob);
    await createGroup(harness, alice, [bob, carol], 'Team');

    const peers = await presence.sharedPeerIds(alice.id);

    expect(new Set(peers)).toEqual(new Set([bob.id, carol.id]));
    expect(peers).not.toContain(dave.id);
    expect(peers).not.toContain(alice.id);
  });

  it('requires auth and validates the user id', async () => {
    const alice = await registerUser(harness, 'Alice');

    const anonymous = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/presence/${alice.id}`,
    });
    const malformed = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/presence/not-a-uuid',
      headers: auth(alice),
    });
    const missing = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/presence/2f40ffbe-0738-4d45-92d2-3249db6b11de',
      headers: auth(alice),
    });

    expect(anonymous.statusCode).toBe(401);
    expect(malformed.statusCode).toBe(422);
    expect(missing.statusCode).toBe(404);
  });
});

describe('message search', () => {
  it('finds messages by word in a conversation the caller belongs to', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    await send(alice, conversationId, 'lunch plans on friday');
    await send(bob, conversationId, 'sounds good, see you then');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/search?q=lunch`,
      headers: auth(bob),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().messages).toHaveLength(1);
    expect(response.json().messages[0]).toMatchObject({
      conversation_id: conversationId,
      content: 'lunch plans on friday',
    });
  });

  it('supports phrase queries via websearch syntax', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);

    await send(alice, conversationId, 'the quick brown fox');
    await send(alice, conversationId, 'a quick red fox');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/search?q=${encodeURIComponent('"quick brown"')}`,
      headers: auth(bob),
    });

    expect(response.json().messages).toHaveLength(1);
    expect(response.json().messages[0].content).toBe('the quick brown fox');
  });

  it('scopes a global search to the caller memberships', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const shared = await createDirect(harness, alice, bob);

    await send(alice, shared, 'project kickoff notes');

    const bobSearch = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/search?q=project',
      headers: auth(bob),
    });
    const eveSearch = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/search?q=project',
      headers: auth(eve),
    });

    expect(bobSearch.statusCode).toBe(200);
    expect(bobSearch.json().messages).toHaveLength(1);
    expect(bobSearch.json().messages[0].conversation_id).toBe(shared);
    // Eve is not in that conversation, so she must see nothing.
    expect(eveSearch.json().messages).toHaveLength(0);
  });

  it('rejects search in a conversation the caller is not a member of', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const conversationId = await createDirect(harness, alice, bob);
    await send(alice, conversationId, 'secret plans');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/search?q=secret`,
      headers: auth(eve),
    });

    expect(response.statusCode).toBe(403);
  });

  it('validates the query and paginates by seq', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const conversationId = await createDirect(harness, alice, bob);
    for (let index = 0; index < 5; index += 1) {
      await send(alice, conversationId, `budget item ${index}`);
    }

    const empty = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/search?q=`,
      headers: auth(bob),
    });
    expect(empty.statusCode).toBe(422);

    const page = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}/search?q=budget&limit=2&before_seq=4`,
      headers: auth(bob),
    });
    expect(page.statusCode).toBe(200);
    expect(page.json().messages.map((message: { seq: number }) => message.seq)).toEqual([3, 2]);
    expect(page.json().has_more).toBe(true);
  });
});
