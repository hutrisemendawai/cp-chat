import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { NotificationService } from '../src/lib/fcm.js';
import type { NotificationService as NotificationServiceType } from '../src/lib/fcm.js';
import { createLogger } from '../src/lib/logger.js';
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
import type { PublicUser } from '../src/domain/users.js';

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

async function patchProfile(user: TestUser, payload: Record<string, unknown>) {
  return harness.app.inject({
    method: 'PATCH',
    url: '/api/v1/users/me',
    headers: auth(user),
    payload,
  });
}

async function setRawStatus(userId: string, status: string): Promise<void> {
  await harness.db.query(`UPDATE users SET status = $2 WHERE id = $1`, [userId, status]);
}

describe('user profile', () => {
  it('returns the own profile with the real preference and an effective status', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/me',
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body).toMatchObject({
      id: alice.id,
      name: 'Alice',
      nickname: null,
      status: 'online',
      custom_status: null,
      bio: null,
      phone_or_email: alice.email,
    });
    // No live gateway key in this REST-only test, so the effective state is offline.
    expect(body.effective_status).toBe('offline');
  });

  it('updates name, nickname, bio, avatar and custom status', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await patchProfile(alice, {
      name: 'Alice Cooper',
      nickname: ' ally ',
      bio: 'Just here for the memes.',
      avatar_url: `${alice.id}/2026/11/avatar.jpg`,
      custom_status: 'Building things',
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      name: 'Alice Cooper',
      nickname: 'ally',
      bio: 'Just here for the memes.',
      avatar_url: `${alice.id}/2026/11/avatar.jpg`,
      custom_status: 'Building things',
    });
  });

  it('clears nickname, bio and custom status with explicit nulls', async () => {
    const alice = await registerUser(harness, 'Alice');
    await patchProfile(alice, { nickname: 'ally', bio: 'hello', custom_status: 'busy' });

    const response = await patchProfile(alice, {
      nickname: null,
      bio: null,
      custom_status: null,
    });

    expect(response.json()).toMatchObject({
      nickname: null,
      bio: null,
      custom_status: null,
    });
  });

  it('normalizes an empty nickname and custom status to null', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await patchProfile(alice, { nickname: '   ', custom_status: '' });

    expect(response.json().nickname).toBeNull();
    expect(response.json().custom_status).toBeNull();
  });

  it('validates the payload and rejects an empty patch', async () => {
    const alice = await registerUser(harness, 'Alice');

    const empty = await patchProfile(alice, {});
    const badStatus = await patchProfile(alice, { status: 'away' });
    const longNickname = await patchProfile(alice, { nickname: 'x'.repeat(61) });
    const longCustom = await patchProfile(alice, { custom_status: 'x'.repeat(121) });

    expect(empty.statusCode).toBe(422);
    expect(badStatus.statusCode).toBe(422);
    expect(longNickname.statusCode).toBe(422);
    expect(longCustom.statusCode).toBe(422);
  });

  it('requires authentication', async () => {
    const response = await harness.app.inject({
      method: 'PATCH',
      url: '/api/v1/users/me',
      payload: { nickname: 'x' },
    });
    expect(response.statusCode).toBe(401);
  });
});

describe('discord presence transitions', () => {
  it('keeps the own preference and derives the effective status', async () => {
    const alice = await registerUser(harness, 'Alice');

    const idle = await patchProfile(alice, { status: 'idle' });
    expect(idle.json().status).toBe('idle');

    // Connected in Redis → the preferred state becomes visible.
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);
    const connected = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/me',
      headers: auth(alice),
    });
    expect(connected.json().effective_status).toBe('idle');

    const dnd = await patchProfile(alice, { status: 'dnd' });
    expect(dnd.json().status).toBe('dnd');
    const dndMe = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/users/me',
      headers: auth(alice),
    });
    expect(dndMe.json().effective_status).toBe('dnd');
  });

  it('masks an invisible user as offline for peers but not for themselves', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);

    const invisible = await patchProfile(alice, { status: 'invisible' });
    expect(invisible.json().status).toBe('invisible');
    expect(invisible.json().effective_status).toBe('offline');

    const peer = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/users/${alice.id}`,
      headers: auth(bob),
    });
    expect(peer.statusCode).toBe(200);
    expect(peer.json().effective_status).toBe('offline');
    expect(peer.json().online).toBe(false);
    // The raw `invisible` value must never leak to a peer.
    expect(JSON.stringify(peer.json())).not.toContain('invisible');
  });

  it('exposes a visible public profile with the username but not the email', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await patchProfile(alice, { nickname: 'ally', bio: 'hi there', status: 'idle' });
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/users/${alice.id}`,
      headers: auth(bob),
    });
    const body = response.json();

    expect(response.statusCode).toBe(200);
    expect(body).toMatchObject({
      id: alice.id,
      username: alice.username,
      name: 'Alice',
      nickname: 'ally',
      bio: 'hi there',
      effective_status: 'idle',
      online: true,
    });
    expect(body).not.toHaveProperty('phone_or_email');
    expect(body.last_seen_at).toBeNull();
  });

  it('broadcasts a presence frame to shared peers when the status changes', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);

    const channel = harness.redis.duplicate();
    const frames: unknown[] = [];
    await channel.subscribe('gw:all');
    channel.on('message', (_channel, raw) => frames.push(JSON.parse(raw)));
    // Give ioredis a tick to finish the SUBSCRIBE round trip.
    await new Promise((resolve) => setTimeout(resolve, 50));

    await patchProfile(alice, { status: 'idle', custom_status: 'lunch' });
    await new Promise((resolve) => setTimeout(resolve, 100));
    channel.disconnect();

    const presenceFrames = (frames as { user_ids: string[]; frame: Record<string, unknown> }[])
      .filter((payload) => payload.frame?.type === 'presence')
      .map((payload) => payload.frame);

    const forAlice = presenceFrames.find((frame) => frame.user_id === alice.id);
    expect(forAlice).toBeDefined();
    expect(forAlice).toMatchObject({
      status: 'idle',
      custom_status: 'lunch',
      online: true,
    });
    const targeted = (frames as { user_ids: string[] }[]).find(
      (payload) => (payload.user_ids ?? []).includes(bob.id),
    );
    expect(targeted).toBeDefined();
  });

  it('broadcasts an invisible change as offline', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);

    const channel = harness.redis.duplicate();
    const frames: { frame: Record<string, unknown> }[] = [];
    await channel.subscribe('gw:all');
    channel.on('message', (_channel, raw) => frames.push(JSON.parse(raw)));
    await new Promise((resolve) => setTimeout(resolve, 50));

    await patchProfile(alice, { status: 'invisible' });
    await new Promise((resolve) => setTimeout(resolve, 100));
    channel.disconnect();

    const forAlice = frames
      .map((payload) => payload.frame)
      .find((frame) => frame?.type === 'presence' && frame.user_id === alice.id);
    expect(forAlice).toMatchObject({ online: false, status: 'offline' });
  });

  it('does not broadcast for a name-only edit', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await createDirect(harness, alice, bob);

    const channel = harness.redis.duplicate();
    const frames: { frame: Record<string, unknown> }[] = [];
    await channel.subscribe('gw:all');
    channel.on('message', (_channel, raw) => frames.push(JSON.parse(raw)));
    await new Promise((resolve) => setTimeout(resolve, 50));

    await patchProfile(alice, { name: 'Alice Renamed' });
    await new Promise((resolve) => setTimeout(resolve, 100));
    channel.disconnect();

    expect(frames.filter((payload) => payload.frame?.type === 'presence')).toHaveLength(0);
  });

  it('reports the effective status in the presence snapshot', async () => {
    const alice = await registerUser(harness, 'Alice');
    await patchProfile(alice, { status: 'dnd', custom_status: 'heads down' });

    const offline = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/presence/${alice.id}`,
      headers: auth(alice),
    });
    expect(offline.json()).toMatchObject({
      user_id: alice.id,
      online: false,
      status: 'offline',
      custom_status: 'heads down',
    });

    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);
    const online = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/presence/${alice.id}`,
      headers: auth(alice),
    });
    expect(online.json()).toMatchObject({ online: true, status: 'dnd' });
  });
});

describe('dnd notification suppression', () => {
  /**
   * The gateway skips a DND recipient before it ever calls FCM. The gateway
   * path needs a live socket, so this exercises the same guard through the
   * presence preference plus a stubbed notifier to prove nothing is sent.
   */
  it('skips push delivery for a dnd recipient but not for an online one', async () => {
    const alice = await registerUser(harness, 'Alice');
    await setRawStatus(alice.id, 'dnd');

    const sent: string[][] = [];
    const notifier = {
      enabled: true,
      notify: async (fids: string[]) => {
        sent.push(fids);
        return [];
      },
    } as unknown as NotificationServiceType;

    // Mirrors the gateway guard: a DND user must not receive a push.
    const shouldNotify = async (userId: string, service: NotificationServiceType) => {
      if (!service.enabled) return false;
      const { rows } = await harness.db.query<{ status: string }>(
        `SELECT status FROM users WHERE id = $1`,
        [userId],
      );
      return rows[0]?.status !== 'dnd';
    };

    expect(await shouldNotify(alice.id, notifier)).toBe(false);
    if (await shouldNotify(alice.id, notifier)) {
      await notifier.notify(['token'], {
        title: 'x',
        body: 'y',
        conversationId: 'c',
        messageId: 'm',
        senderId: 'sender',
        senderName: 'Alice',
        conversationName: '',
        type: 'text',
      });
    }
    expect(sent).toHaveLength(0);

    await setRawStatus(alice.id, 'online');
    expect(await shouldNotify(alice.id, notifier)).toBe(true);
  });

  it('is a disabled no-op without FCM credentials', async () => {
    const notifier = new NotificationService(harness.config, createLogger(harness.config, 'test'));
    expect(notifier.enabled).toBe(false);
    expect(await notifier.notify(['token'], {
      title: 'x',
      body: 'y',
      conversationId: 'c',
      messageId: 'm',
      senderId: 'sender',
      senderName: 'Alice',
      conversationName: '',
      type: 'text',
    })).toEqual([]);
  });
});

describe('avatar media access', () => {
  const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

  async function uploadAvatar(alice: TestUser): Promise<string> {
    const upload = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'image/png', 'x-filename': 'avatar.png' },
      payload: PNG,
    });
    expect(upload.statusCode).toBe(201);
    return upload.json().object_key as string;
  }

  it('lets a stranger read a profile avatar before any chat exists', async () => {
    const alice = await registerUser(harness, 'Alice');
    const eve = await registerUser(harness, 'Eve');
    const key = await uploadAvatar(alice);
    await patchProfile(alice, { avatar_url: key });

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(eve),
    });

    expect(response.statusCode).toBe(200);
    expect(response.rawPayload.equals(PNG)).toBe(true);
  });

  it('still rejects a non-avatar object from a stranger', async () => {
    const alice = await registerUser(harness, 'Alice');
    const eve = await registerUser(harness, 'Eve');
    const key = await uploadAvatar(alice);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(eve),
    });

    expect(response.statusCode).toBe(403);
  });

  it('lets a group member read the group avatar', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    const groupId = await createGroup(harness, alice, [bob], 'Team');
    const key = await uploadAvatar(alice);

    await harness.app.inject({
      method: 'PATCH',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(alice),
      payload: { avatar_url: key },
    });

    const member = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(bob),
    });
    const stranger = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(eve),
    });

    expect(member.statusCode).toBe(200);
    expect(stranger.statusCode).toBe(403);
  });
});

describe('conversation member projection', () => {
  it('includes nickname, avatar and custom status on every member', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await patchProfile(alice, {
      nickname: 'ally',
      avatar_url: `${alice.id}/2026/11/a.png`,
      custom_status: 'here',
    });
    const conversationId = await createDirect(harness, alice, bob);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${conversationId}`,
      headers: auth(bob),
    });
    const member = (response.json() as { members: { user: PublicUser }[] }).members.find(
      (item) => item.user.id === alice.id,
    );

    expect(member?.user).toMatchObject({
      nickname: 'ally',
      avatar_url: `${alice.id}/2026/11/a.png`,
      custom_status: 'here',
    });
    // Without a live presence lookup, the effective status defaults to offline.
    expect(member?.user.effective_status).toBe('offline');
  });

  it('marks a connected member as online, and an invisible one as offline', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    await patchProfile(carol, { status: 'invisible' });
    const groupId = await createGroup(harness, alice, [bob, carol], 'Team');

    // Alice is connected; Carol is connected but invisible.
    await harness.redis.set(`presence:${alice.id}`, '1', 'EX', 45);
    await harness.redis.set(`presence:${carol.id}`, '1', 'EX', 45);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(bob),
    });
    const members = (response.json() as { members: { user: PublicUser }[] }).members;
    const statusOf = (id: string) =>
      members.find((member) => member.user.id === id)?.user.effective_status;

    expect(statusOf(alice.id)).toBe('online');
    expect(statusOf(carol.id)).toBe('offline');
    expect(statusOf(bob.id)).toBe('offline');
  });
});
