import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { MessageRepository } from '../src/domain/messages.js';
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

async function search(
  caller: TestUser,
  q: string,
  params: { limit?: number; offset?: number } = {},
) {
  return harness.app.inject({
    method: 'GET',
    url: '/api/v1/users/search',
    headers: auth(caller),
    query: {
      q,
      ...(params.limit !== undefined ? { limit: String(params.limit) } : {}),
      ...(params.offset !== undefined ? { offset: String(params.offset) } : {}),
    },
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

type SearchUser = {
  id: string;
  username: string;
  name: string;
  nickname: string | null;
  avatar_url: string | null;
};

describe('user search', () => {
  it('finds users by a username substring, excludes the caller and never leaks the email', async () => {
    const alice = await registerUser(harness, 'Alice Anderson');
    const bob = await registerUser(harness, 'Bob Builder');

    const response = await search(alice, bob.username);

    expect(response.statusCode).toBe(200);
    const body = response.json();
    const users = body.users as Record<string, unknown>[];
    const found = users.find((user) => user.id === bob.id);
    expect(found).toMatchObject({ id: bob.id, username: bob.username, name: 'Bob Builder' });
    expect(found).not.toHaveProperty('phone_or_email');
    expect(JSON.stringify(body)).not.toContain(bob.email);
    expect(users.map((user) => user.id)).not.toContain(alice.id);
    expect(body).toMatchObject({ limit: 10, offset: 0, has_more: false, next_offset: null });
  });

  it('finds users by an email substring without returning the email', async () => {
    const alice = await registerUser(harness, 'Alice');
    const carol = await registerUser(harness, 'Carol');
    const token = carol.email.split('+')[1]!.split('@')[0]!;

    const response = await search(alice, token.slice(0, 10));

    expect(response.statusCode).toBe(200);
    const found = (response.json().users as Record<string, unknown>[]).find(
      (user) => user.id === carol.id,
    );
    expect(found).toBeDefined();
    expect(found).not.toHaveProperty('phone_or_email');
  });

  it('ranks an exact username above a mid-string match', async () => {
    const alice = await registerUser(harness, 'Alice');
    const stem = `stem${crypto.randomUUID().replace(/-/g, '').slice(0, 8)}`;

    const { rows } = await harness.db.query<{ id: string; username: string }>(
      `INSERT INTO users (username, phone_or_email, name, password_hash) VALUES
         ($1, $2, 'Exact', 'x'), ($3, $4, 'Mid', 'x')
       RETURNING id, username`,
      [
        stem,
        `exact-${alice.id.slice(0, 8)}@example.com`,
        `zz${stem}zz`,
        `mid-${alice.id.slice(0, 8)}@example.com`,
      ],
    );
    const exact = rows.find((row) => row.username === stem)!;
    const mid = rows.find((row) => row.username !== stem)!;

    const response = await search(alice, stem);

    expect(response.statusCode).toBe(200);
    const users = response.json().users as SearchUser[];
    expect(users[0]?.id).toBe(exact.id);
    expect(users.map((user) => user.id)).toContain(mid.id);
  });

  it('paginates 10 at a time with no duplicates and an accurate has_more', async () => {
    const alice = await registerUser(harness, 'Alice');
    const token = `pg${crypto.randomUUID().replace(/-/g, '').slice(0, 8)}`;

    const usernames = Array.from({ length: 25 }, (_, index) => `${token}_${index}`);
    const emails = Array.from({ length: 25 }, (_, index) => `${token}-${index}@example.com`);
    const names = Array.from({ length: 25 }, (_, index) => `Pg ${index}`);
    await harness.db.query(
      `INSERT INTO users (username, phone_or_email, name, password_hash)
       SELECT * FROM unnest($1::text[], $2::text[], $3::text[], $4::text[])`,
      [usernames, emails, names, Array.from({ length: 25 }, () => 'x')],
    );

    const first = await search(alice, token);
    const firstBody = first.json();
    expect(firstBody.users).toHaveLength(10);
    expect(firstBody).toMatchObject({ limit: 10, offset: 0, has_more: true, next_offset: 10 });

    const second = await search(alice, token, { offset: 10 });
    const secondBody = second.json();
    expect(secondBody.users).toHaveLength(10);
    expect(secondBody).toMatchObject({ has_more: true, next_offset: 20 });

    const third = await search(alice, token, { offset: 20 });
    const thirdBody = third.json();
    expect(thirdBody.users).toHaveLength(5);
    expect(thirdBody).toMatchObject({ has_more: false, next_offset: null });

    const all = [
      ...(firstBody.users as SearchUser[]),
      ...(secondBody.users as SearchUser[]),
      ...(thirdBody.users as SearchUser[]),
    ];
    expect(new Set(all.map((user) => user.id)).size).toBe(25);
  });

  it('enforces the minimum query length, a non-negative offset and clamps the limit', async () => {
    const alice = await registerUser(harness, 'Alice');
    await registerUser(harness, 'Query Target');

    expect((await search(alice, '')).statusCode).toBe(422);
    expect((await search(alice, 'ab')).statusCode).toBe(422);
    expect((await search(alice, 'query', { limit: 0 })).statusCode).toBe(422);
    expect((await search(alice, 'query', { offset: -1 })).statusCode).toBe(422);

    const clamped = await search(alice, 'query', { limit: 50 });
    expect(clamped.statusCode).toBe(200);
    expect((clamped.json().users as SearchUser[]).length).toBeLessThanOrEqual(10);
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

  it('a one-way friendship never blocks conversation or message access', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    // Alice adds Bob; Bob has not (and must not need to) add Alice.
    await addFriend(alice, { user_id: bob.id });

    const created = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', member_ids: [bob.id] },
    });
    expect(created.statusCode).toBe(201);
    const conversationId = created.json().id as string;

    const repo = new MessageRepository(harness.db);
    for (let index = 0; index < 2; index += 1) {
      await repo.append({
        conversationId,
        senderId: alice.id,
        clientMsgId: randomUUID(),
        type: 'text',
        content: `hello ${index}`,
      });
    }

    // Bob can list and read the conversation with Alice's full profile.
    const list = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(bob),
    });
    const entry = list
      .json()
      .conversations.find((conversation: { id: string }) => conversation.id === conversationId);
    expect(entry).toBeDefined();
    const aliceMember = entry.members.find(
      (member: { user: { id: string } }) => member.user.id === alice.id,
    );
    expect(aliceMember.user).toMatchObject({ name: 'Alice' });
    expect(aliceMember.user).toHaveProperty('avatar_url');
    expect(aliceMember.user).toHaveProperty('nickname');

    const summary = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}`,
      headers: auth(bob),
    });
    expect(summary.statusCode).toBe(200);
    expect(summary.json().members).toHaveLength(2);

    // Bob's friends list stays empty (the relationship is directed).
    const bobFriends = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/friends',
      headers: auth(bob),
    });
    expect(bobFriends.json().friends).toEqual([]);
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
