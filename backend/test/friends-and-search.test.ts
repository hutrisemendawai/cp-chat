import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import {
  auth,
  createHarness,
  registerUser,
  truncateAll,
  type TestHarness,
  type TestUser,
} from './helpers.js';

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

async function search(caller: TestUser, q: string, limit?: number) {
  return harness.app.inject({
    method: 'GET',
    url: '/api/v1/users/search',
    headers: auth(caller),
    query: { q, ...(limit !== undefined ? { limit: String(limit) } : {}) },
  });
}

async function addFriend(caller: TestUser, payload: Record<string, unknown>) {
  return harness.app.inject({
    method: 'POST',
    url: '/api/v1/friends',
    headers: auth(caller),
    payload,
  });
}

describe('user search', () => {
  it('finds users by a name substring and excludes the caller', async () => {
    const alice = await registerUser(harness, 'Alice Anderson');
    const bob = await registerUser(harness, 'Bob Builder');

    const response = await search(alice, 'bob');

    expect(response.statusCode).toBe(200);
    const users = response.json().users as { id: string; name: string; is_friend: boolean }[];
    expect(users.map((user) => user.id)).toContain(bob.id);
    expect(users.map((user) => user.id)).not.toContain(alice.id);
    expect(users.find((user) => user.id === bob.id)).toMatchObject({
      name: 'Bob Builder',
      is_friend: false,
    });
  });

  it('finds users by an email substring', async () => {
    const alice = await registerUser(harness, 'Alice');
    const carol = await registerUser(harness, 'Carol');

    const response = await search(alice, carol.email);

    expect(response.statusCode).toBe(200);
    const found = (response.json().users as { id: string }[]).find(
      (user) => user.id === carol.id,
    );
    expect(found).toBeDefined();
  });

  it('reports is_friend and the public profile fields', async () => {
    const alice = await registerUser(harness, 'Alice');
    const dave = await registerUser(harness, 'Dave');
    await addFriend(alice, { user_id: dave.id });

    const response = await search(alice, 'Dave');

    expect(response.statusCode).toBe(200);
    const found = (response.json().users as Record<string, unknown>[]).find(
      (user) => user.id === dave.id,
    );
    expect(found).toMatchObject({
      id: dave.id,
      name: 'Dave',
      phone_or_email: dave.email,
      is_friend: true,
      effective_status: 'offline',
      online: false,
    });
  });

  it('orders an exact email match above a name match', async () => {
    const alice = await registerUser(harness, 'Alice');
    const prefix = `lookup-${alice.id.slice(0, 8)}`;

    // The name-match row's email deliberately does not start with the query so
    // only its name ranks it, while the exact row matches by email prefix.
    const { rows } = await harness.db.query<{ id: string; name: string }>(
      `INSERT INTO users (phone_or_email, name, password_hash) VALUES
         ($1, 'Zed', 'x'), ($2, $3, 'x')
       RETURNING id, name`,
      [`${prefix}@example.com`, `other-${alice.id.slice(0, 8)}@example.com`, `${prefix} Person`],
    );
    const exact = rows.find((row) => row.name === 'Zed')!;
    const named = rows.find((row) => row.name !== 'Zed')!;

    const response = await search(alice, prefix);

    expect(response.statusCode).toBe(200);
    const users = response.json().users as { id: string }[];
    expect(users[0]?.id).toBe(exact.id);
    expect(users.map((user) => user.id)).toContain(named.id);
  });

  it('validates the query and the limit', async () => {
    const alice = await registerUser(harness, 'Alice');

    expect((await search(alice, '')).statusCode).toBe(422);
    expect((await search(alice, 'a', 0)).statusCode).toBe(422);
    expect((await search(alice, 'a', 51)).statusCode).toBe(422);
  });

  it('requires authentication', async () => {
    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/search',
      query: { q: 'bob' },
    });
    expect(response.statusCode).toBe(401);
  });
});

describe('friends', () => {
  it('adds a friend by user id and lists them', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    const added = await addFriend(alice, { user_id: bob.id });
    expect(added.statusCode).toBe(201);
    expect(added.json()).toMatchObject({ id: bob.id, name: 'Bob', is_friend: true });

    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/friends',
      headers: auth(alice),
    });
    expect(list.statusCode).toBe(200);
    expect((list.json().friends as { id: string }[]).map((user) => user.id)).toEqual([bob.id]);

    // The relationship is directed: Bob has not added Alice.
    const bobList = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/friends',
      headers: auth(bob),
    });
    expect(bobList.json().friends).toEqual([]);
  });

  it('adds a friend by email and is idempotent', async () => {
    const alice = await registerUser(harness, 'Alice');
    const carol = await registerUser(harness, 'Carol');

    const first = await addFriend(alice, { identifier: carol.email });
    const second = await addFriend(alice, { identifier: carol.email });

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(201);

    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/friends',
      headers: auth(alice),
    });
    expect(list.json().friends).toHaveLength(1);
  });

  it('rejects adding yourself and unknown identifiers', async () => {
    const alice = await registerUser(harness, 'Alice');

    expect((await addFriend(alice, { user_id: alice.id })).statusCode).toBe(422);
    expect((await addFriend(alice, { identifier: 'nobody@example.com' })).statusCode).toBe(404);
    expect((await addFriend(alice, {})).statusCode).toBe(422);
  });

  it('removes a friend', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await addFriend(alice, { user_id: bob.id });

    const removed = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/friends/${bob.id}`,
      headers: auth(alice),
    });
    expect(removed.statusCode).toBe(204);

    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/friends',
      headers: auth(alice),
    });
    expect(list.json().friends).toEqual([]);
  });

  it('marks the relationship on the public profile', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await addFriend(alice, { user_id: bob.id });

    const profile = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/users/${bob.id}`,
      headers: auth(alice),
    });
    expect(profile.json().is_friend).toBe(true);
  });
});

describe('presence fan-out to friends', () => {
  it('broadcasts a presence change to a friend who shares no conversation', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await addFriend(bob, { user_id: alice.id });

    const channel = harness.redis.duplicate();
    const frames: { user_ids: string[]; frame: Record<string, unknown> }[] = [];
    await channel.subscribe('gw:all');
    channel.on('message', (_channel, raw) => frames.push(JSON.parse(raw)));
    await new Promise((resolve) => setTimeout(resolve, 50));

    await harness.app.inject({
      method: 'PATCH',
      url: '/api/v1/users/me',
      headers: auth(alice),
      payload: { status: 'idle' },
    });
    await new Promise((resolve) => setTimeout(resolve, 100));
    channel.disconnect();

    const presence = frames
      .filter((payload) => payload.frame?.type === 'presence')
      .find((payload) => payload.frame.user_id === alice.id);
    expect(presence).toBeDefined();
    expect(presence!.user_ids).toContain(bob.id);
  });
});
