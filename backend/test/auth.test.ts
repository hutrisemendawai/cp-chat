import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import {
  auth,
  createDirect,
  createHarness,
  registerUser,
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

describe('auth', () => {
  it('registers a user and issues both tokens', async () => {
    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: 'new@example.com', name: 'New', password: 'password123' },
    });

    expect(response.statusCode).toBe(201);
    const body = response.json();
    expect(body.user).toMatchObject({ name: 'New', phone_or_email: 'new@example.com' });
    expect(body.access_token).toBeTypeOf('string');
    expect(body.refresh_token).toBeTypeOf('string');
    expect(body.expires_in).toBe(900);
    expect(body.user).not.toHaveProperty('password_hash');
  });

  it('rejects a duplicate contact regardless of case', async () => {
    await registerUser(harness, 'Case User');
    const email = `${'case.user'}+${crypto.randomUUID()}@example.com`;

    const first = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: email, name: 'A', password: 'password123' },
    });
    const second = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: email.toUpperCase(), name: 'B', password: 'password123' },
    });

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(409);
  });

  it('rejects weak passwords and short names with a validation error', async () => {
    const shortPassword = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: 'weak@example.com', name: 'Weak', password: 'short' },
    });
    const emptyName = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: 'noname@example.com', name: '', password: 'password123' },
    });

    expect(shortPassword.statusCode).toBe(422);
    expect(shortPassword.json().error.code).toBe('validation_error');
    expect(emptyName.statusCode).toBe(422);
  });

  it('logs in with the correct password and rejects the wrong one', async () => {
    const user = await registerUser(harness, 'Login User');

    const ok = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { phone_or_email: user.email, password: 'password123' },
    });
    const bad = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { phone_or_email: user.email, password: 'wrong-password' },
    });
    const unknown = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { phone_or_email: 'ghost@example.com', password: 'password123' },
    });

    expect(ok.statusCode).toBe(200);
    expect(bad.statusCode).toBe(401);
    expect(bad.json().error.code).toBe('invalid_credentials');
    expect(unknown.statusCode).toBe(401);
  });

  it('rotates refresh tokens and rejects reuse', async () => {
    const user = await registerUser(harness, 'Rotate User');

    const rotated = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refresh_token: user.refreshToken, device_id: user.deviceId },
    });
    expect(rotated.statusCode).toBe(200);
    const next = rotated.json();
    expect(next.refresh_token).not.toBe(user.refreshToken);

    // Presenting the original token again is a replay: it must fail, and the
    // whole family is revoked so the freshly issued token dies too.
    const replay = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refresh_token: user.refreshToken },
    });
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error.code).toBe('invalid_token');

    const afterFamilyRevoke = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refresh_token: next.refresh_token },
    });
    expect(afterFamilyRevoke.statusCode).toBe(401);
  });

  it('revokes the refresh token on logout', async () => {
    const user = await registerUser(harness, 'Logout User');

    const logout = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/logout',
      headers: auth(user),
      payload: { refresh_token: user.refreshToken },
    });
    expect(logout.statusCode).toBe(204);

    const refresh = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/refresh',
      payload: { refresh_token: user.refreshToken },
    });
    expect(refresh.statusCode).toBe(401);
  });

  it('protects /users/me and never leaks the password hash', async () => {
    const user = await registerUser(harness, 'Me User');

    const me = await harness.app.inject({ method: 'GET', url: '/api/v1/users/me', headers: auth(user) });
    const anonymous = await harness.app.inject({ method: 'GET', url: '/api/v1/users/me' });
    const garbage = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/me',
      headers: { authorization: 'Bearer not-a-jwt' },
    });

    expect(me.statusCode).toBe(200);
    expect(me.json().id).toBe(user.id);
    expect(me.json()).not.toHaveProperty('password_hash');
    expect(anonymous.statusCode).toBe(401);
    expect(garbage.statusCode).toBe(401);
  });

  it('hides the contact of other users', async () => {
    const viewer = await registerUser(harness, 'Viewer User');
    const other = await registerUser(harness, 'Other User');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/users/${other.id}`,
      headers: auth(viewer),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).not.toHaveProperty('phone_or_email');
  });
});

describe('conversations', () => {
  it('creates a direct conversation idempotently from either side', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    const first = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', member_ids: [bob.id] },
    });
    const second = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(bob),
      payload: { type: 'direct', member_ids: [alice.id] },
    });

    expect(first.statusCode).toBe(201);
    expect(second.json().id).toBe(first.json().id);
    expect(first.json().members).toHaveLength(2);
    expect(first.json().last_seq).toBe(0);
    expect(first.json().unread_count).toBe(0);
  });

  it('rejects a self conversation and unknown members', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    const self = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', member_ids: [alice.id] },
    });
    const group = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'group', name: 'Team', member_ids: [bob.id] },
    });
    const unknown = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', member_ids: [crypto.randomUUID()] },
    });

    expect(self.statusCode).toBe(422);
    // Phase 2 enables groups: the creator is the admin and the payload is valid.
    expect(group.statusCode).toBe(201);
    expect(group.json().type).toBe('group');
    expect(unknown.statusCode).toBe(404);
  });

  it('lists only the caller conversations, newest activity first', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');

    const withBob = await createDirect(harness, alice, bob);
    await createDirect(harness, carol, bob);

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations',
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(200);
    const ids = response.json().conversations.map((conversation: { id: string }) => conversation.id);
    expect(ids).toEqual([withBob]);
    expect(response.json().next_cursor).toBeNull();
  });

  it('forbids reading a conversation the caller does not belong to', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const conversationId = await createDirect(harness, alice, bob);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}`,
      headers: auth(eve),
    });

    expect(response.statusCode).toBe(403);
    expect(response.json().error.code).toBe('not_a_member');
  });

  it('rejects a malformed conversation id', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/conversations/not-a-uuid',
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(422);
  });
});
