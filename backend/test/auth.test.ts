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
      payload: {
        phone_or_email: 'new@example.com',
        username: 'new_user',
        name: 'New',
        password: 'password123',
      },
    });

    expect(response.statusCode).toBe(201);
    const body = response.json();
    expect(body.user).toMatchObject({
      name: 'New',
      username: 'new_user',
      phone_or_email: 'new@example.com',
    });
    expect(body.access_token).toBeTypeOf('string');
    expect(body.refresh_token).toBeTypeOf('string');
    expect(body.expires_in).toBe(900);
    expect(body.user).not.toHaveProperty('password_hash');
  });

  it('normalizes the username to lowercase and rejects missing or malformed ones', async () => {
    const upper = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: `upper-${crypto.randomUUID()}@example.com`,
        username: 'Mixed_Case.Name',
        name: 'Mixed',
        password: 'password123',
      },
    });
    expect(upper.statusCode).toBe(201);
    expect(upper.json().user.username).toBe('mixed_case.name');

    const missing = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: { phone_or_email: 'nouser@example.com', name: 'NoUser', password: 'password123' },
    });
    const withAt = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'at@example.com',
        username: 'bad@name',
        name: 'At',
        password: 'password123',
      },
    });
    const leadingDot = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'dot@example.com',
        username: '.dotname',
        name: 'Dot',
        password: 'password123',
      },
    });
    const doubleDot = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'doubledot@example.com',
        username: 'a..b',
        name: 'Double',
        password: 'password123',
      },
    });
    const tooShort = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'short@example.com',
        username: 'ab',
        name: 'Short',
        password: 'password123',
      },
    });

    for (const response of [missing, withAt, leadingDot, doubleDot, tooShort]) {
      expect(response.statusCode).toBe(422);
      expect(response.json().error.code).toBe('validation_error');
    }
  });

  it('rejects a duplicate contact regardless of case', async () => {
    await registerUser(harness, 'Case User');
    const email = `${'case.user'}+${crypto.randomUUID()}@example.com`;

    const first = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: email,
        username: `casea_${crypto.randomUUID().slice(0, 6)}`,
        name: 'A',
        password: 'password123',
      },
    });
    const second = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: email.toUpperCase(),
        username: `caseb_${crypto.randomUUID().slice(0, 6)}`,
        name: 'B',
        password: 'password123',
      },
    });

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(409);
  });

  it('rejects a duplicate username case-insensitively', async () => {
    const first = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: `taken-${crypto.randomUUID()}@example.com`,
        username: 'taken_name',
        name: 'First',
        password: 'password123',
      },
    });
    const second = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: `taken2-${crypto.randomUUID()}@example.com`,
        username: 'TAKEN_NAME',
        name: 'Second',
        password: 'password123',
      },
    });

    expect(first.statusCode).toBe(201);
    expect(second.statusCode).toBe(409);
    expect(second.json().error.message).toBe('Username is already taken');
  });

  it('rejects weak passwords and short names with a validation error', async () => {
    const shortPassword = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'weak@example.com',
        username: 'weak_user',
        name: 'Weak',
        password: 'short',
      },
    });
    const emptyName = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/register',
      payload: {
        phone_or_email: 'noname@example.com',
        username: 'no_name',
        name: '',
        password: 'password123',
      },
    });

    expect(shortPassword.statusCode).toBe(422);
    expect(shortPassword.json().error.code).toBe('validation_error');
    expect(emptyName.statusCode).toBe(422);
  });

  it('logs in with the email, the username, and rejects invalid credentials', async () => {
    const user = await registerUser(harness, 'Login User');

    const byEmail = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { identifier: user.email, password: 'password123' },
    });
    const byUsername = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { identifier: user.username.toUpperCase(), password: 'password123' },
    });
    // Backward compatibility: the legacy `phone_or_email` field still works.
    const legacy = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { phone_or_email: user.email, password: 'password123' },
    });
    const bad = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { identifier: user.email, password: 'wrong-password' },
    });
    const unknown = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: { identifier: 'ghost@example.com', password: 'password123' },
    });

    expect(byEmail.statusCode).toBe(200);
    expect(byEmail.json().user.username).toBe(user.username);
    expect(byUsername.statusCode).toBe(200);
    expect(byUsername.json().user.id).toBe(user.id);
    expect(legacy.statusCode).toBe(200);
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

  it('exposes the username but never the email on another user', async () => {
    const viewer = await registerUser(harness, 'Viewer User');
    const other = await registerUser(harness, 'Other User');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/users/${other.id}`,
      headers: auth(viewer),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().username).toBe(other.username);
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
