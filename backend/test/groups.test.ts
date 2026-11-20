import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { ConversationRepository } from '../src/domain/conversations.js';
import {
  auth,
  createGroup,
  createHarness,
  registerUser,
  seedUsers,
  truncateAll,
  type TestHarness,
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

async function groupWith(count: number) {
  const creator = await registerUser(harness, 'Creator');
  const others = await Promise.all(
    Array.from({ length: count }, (_, index) => registerUser(harness, `Member${index}`)),
  );
  const groupId = await createGroup(harness, creator, others, 'Team');
  return { creator, others, groupId };
}

describe('group creation', () => {
  it('creates a group with the creator as the only admin', async () => {
    const { creator, others, groupId } = await groupWith(3);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(creator),
    });
    const body = response.json();

    expect(response.statusCode).toBe(200);
    expect(body.type).toBe('group');
    expect(body.name).toBe('Team');
    expect(body.members).toHaveLength(4);
    expect(body.members.filter((member: { role: string }) => member.role === 'admin')).toHaveLength(1);
    expect(body.members.find((member: { user: { id: string } }) => member.user.id === creator.id).role).toBe(
      'admin',
    );
    expect(others.length).toBe(3);
  });

  it('requires a name', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    const missing = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'group', member_ids: [bob.id] },
    });

    expect(missing.statusCode).toBe(422);
    expect(missing.json().error.code).toBe('validation_error');
  });

  it('rejects a group with no other members', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'group', name: 'Solo', member_ids: [] as string[] },
    });

    expect(response.statusCode).toBe(422);
  });

  it('lets a member receive the group in their conversation list', async () => {
    const { others, groupId } = await groupWith(2);

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(others[0]!),
    });
    const ids = response.json().conversations.map((conversation: { id: string }) => conversation.id);

    expect(ids).toContain(groupId);
  });
});

describe('group metadata updates', () => {
  it('lets an admin rename the group and rejects a plain member', async () => {
    const { creator, others, groupId } = await groupWith(2);

    const renamed = await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(creator),
      payload: { name: 'Renamed' },
    });
    const forbidden = await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(others[0]!),
      payload: { name: 'Hijacked' },
    });

    expect(renamed.statusCode).toBe(200);
    expect(renamed.json().name).toBe('Renamed');
    expect(forbidden.statusCode).toBe(403);
    expect(forbidden.json().error.code).toBe('not_an_admin');
  });

  it('sets and clears the avatar', async () => {
    const { creator, groupId } = await groupWith(1);

    const set = await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(creator),
      payload: { avatar_url: 'creator/2026/11/avatar.jpg' },
    });
    const cleared = await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(creator),
      payload: { avatar_url: null },
    });

    expect(set.json().avatar_url).toBe('creator/2026/11/avatar.jpg');
    expect(cleared.json().avatar_url).toBeNull();
  });

  it('rejects patching a direct conversation', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const direct = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', member_ids: [bob.id] },
    });

    const response = await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${direct.json().id}`,
      headers: auth(alice),
      payload: { name: 'Nope' },
    });

    expect(response.statusCode).toBe(422);
    expect(response.json().error.code).toBe('unsupported_conversation_type');
  });
});

describe('group membership', () => {
  it('lets an admin add members and a plain member cannot', async () => {
    const { creator, others, groupId } = await groupWith(1);
    const newbie = await registerUser(harness, 'Newbie');

    const added = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${groupId}/members`,
      headers: auth(creator),
      payload: { user_ids: [newbie.id] },
    });
    const denied = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${groupId}/members`,
      headers: auth(others[0]!),
      payload: { user_ids: [newbie.id] },
    });

    expect(added.statusCode).toBe(200);
    expect(
      added.json().some((member: { user: { id: string } }) => member.user.id === newbie.id),
    ).toBe(true);
    expect(denied.statusCode).toBe(403);
    expect(denied.json().error.code).toBe('not_an_admin');
  });

  it('enforces the maximum member limit when adding', async () => {
    const [creator, ...existing] = await seedUsers(harness, 500);
    const conversation = await new ConversationRepository(harness.db).createGroup({
      creatorId: creator!.id,
      name: 'Maxed',
      memberIds: existing.map((user) => user.id),
      maxMembers: 500,
    });
    const [extra] = await seedUsers(harness, 1);

    const response = await harness.app.inject({
      method: 'POST',
      url: `/api/v1/conversations/${conversation.id}/members`,
      headers: auth(creator!),
      payload: { user_ids: [extra!.id] },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe('group_full');
  });

  it('lets a member leave and an admin remove someone else', async () => {
    const { creator, others, groupId } = await groupWith(2);
    const [leaver, removed] = others;

    const leave = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${leaver!.id}`,
      headers: auth(leaver!),
    });
    const kick = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${removed!.id}`,
      headers: auth(creator),
    });

    expect(leave.statusCode).toBe(204);
    expect(kick.statusCode).toBe(204);

    const summary = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(creator),
    });
    // Started with creator + 2 members; both others are gone.
    expect(summary.json().members).toHaveLength(1);
    expect(summary.json().members[0].user.id).toBe(creator.id);
  });

  it('prevents a member from removing someone else', async () => {
    const { others, groupId } = await groupWith(2);
    const [actor, target] = others;

    const response = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${target!.id}`,
      headers: auth(actor!),
    });

    expect(response.statusCode).toBe(403);
    expect(response.json().error.code).toBe('not_an_admin');
  });

  it('keeps at least one admin in a non-empty group', async () => {
    const { creator, groupId } = await groupWith(1);

    const response = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${creator.id}`,
      headers: auth(creator),
    });

    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe('last_admin');
  });

  it('deletes the group when the last member leaves', async () => {
    const { creator, others, groupId } = await groupWith(1);

    const removed = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${others[0]!.id}`,
      headers: auth(creator),
    });
    const left = await harness.app.inject({
      method: 'DELETE',
      url: `/api/v1/conversations/${groupId}/members/${creator.id}`,
      headers: auth(creator),
    });

    expect(removed.statusCode).toBe(204);
    expect(left.statusCode).toBe(204);

    const { rows } = await harness.db.query(`SELECT 1 FROM conversations WHERE id = $1`, [groupId]);
    expect(rows).toHaveLength(0);
  });
});
