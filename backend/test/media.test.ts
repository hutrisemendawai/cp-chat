import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import {
  auth,
  createDirect,
  createGroup,
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

describe('media presign', () => {
  it('returns a presigned upload bound to a tracked object key', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'photo.jpg', content_type: 'image/jpeg', size_bytes: 2048 },
    });
    const body = response.json();

    expect(response.statusCode).toBe(201);
    expect(body.media_id).toBeTruthy();
    expect(body.upload_url).toContain('X-Amz-Signature=');
    expect(body.object_key).toMatch(new RegExp(`^${alice.id}/\\d{4}/\\d{2}/[0-9a-f-]+\\.jpg$`));
    expect(body.file_url).toContain(body.object_key);
    expect(body.content_type).toBe('image/jpeg');

    const { rows } = await harness.db.query<{ owner_id: string; size_bytes: string }>(
      `SELECT owner_id, size_bytes FROM media_objects WHERE object_key = $1`,
      [body.object_key],
    );
    expect(rows[0]!.owner_id).toBe(alice.id);
    expect(rows[0]!.size_bytes).toBe('2048');
  });

  it('derives the extension from the content type when the name has none', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'attachment', content_type: 'application/pdf', size_bytes: 10 },
    });

    expect(response.json().object_key).toMatch(/\.pdf$/);
  });

  it('rejects unsupported content types and oversized files', async () => {
    const alice = await registerUser(harness, 'Alice');

    const badType = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'evil.exe', content_type: 'application/x-msdownload', size_bytes: 10 },
    });
    const tooBig = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'movie.mp4', content_type: 'video/mp4', size_bytes: 500_000_000 },
    });

    expect(badType.statusCode).toBe(415);
    expect(badType.json().error.code).toBe('unsupported_media_type');
    expect(tooBig.statusCode).toBe(413);
    expect(tooBig.json().error.code).toBe('media_too_large');
  });

  it('requires authentication', async () => {
    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      payload: { filename: 'a.png', content_type: 'image/png', size_bytes: 1 },
    });
    expect(response.statusCode).toBe(401);
  });

  it('lets the owner and a conversation partner resolve media, but not strangers', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    await createDirect(harness, alice, bob);

    const presign = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'pic.png', content_type: 'image/png', size_bytes: 5 },
    });
    const key = presign.json().object_key as string;

    const owner = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(alice),
    });
    const partner = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(bob),
    });
    const stranger = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}`,
      headers: auth(eve),
    });

    // Both the owner and the partner get redirected to a presigned GET.
    expect(owner.statusCode).toBe(302);
    expect(partner.statusCode).toBe(302);
    expect(stranger.statusCode).toBe(403);
  });

  it('accepts a query token for handlers that cannot set headers', async () => {
    const alice = await registerUser(harness, 'Alice');

    const presign = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/presign',
      headers: auth(alice),
      payload: { filename: 'pic.png', content_type: 'image/png', size_bytes: 5 },
    });
    const key = presign.json().object_key as string;

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${key}?token=${encodeURIComponent(alice.accessToken)}`,
    });

    expect(response.statusCode).toBe(302);
  });

  it('404s an unknown media key', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${alice.id}/2026/11/${randomUUID()}.png`,
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(404);
  });
});

describe('group conversation basics', () => {
  it('starts a group at seq 0 and shows every member', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const carol = await registerUser(harness, 'Carol');
    const groupId = await createGroup(harness, alice, [bob, carol], 'Friends');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/conversations/${groupId}`,
      headers: auth(bob),
    });
    const body = response.json();

    expect(body.last_seq).toBe(0);
    expect(body.members.map((member: { user: { name: string } }) => member.user.name).sort()).toEqual([
      'Alice',
      'Bob',
      'Carol',
    ]);
  });
});
