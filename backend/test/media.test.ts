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

    // Both the owner and the partner are authorized; the object was never
    // uploaded, so the proxied download reports it missing.
    expect(owner.statusCode).toBe(404);
    expect(partner.statusCode).toBe(404);
    expect(stranger.statusCode).toBe(403);
  });

  it('redirects to a presigned GET when proxying is disabled', async () => {
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
      url: `/api/v1/media/${key}?proxy=0`,
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toContain('X-Amz-Signature=');
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
      url: `/api/v1/media/${key}?token=${encodeURIComponent(alice.accessToken)}&proxy=0`,
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

describe('media proxy upload', () => {
  const PNG_BYTES = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01]);

  it('stores the bytes and serves them back through the API without a redirect', async () => {
    const alice = await registerUser(harness, 'Alice');

    const upload = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'image/png', 'x-filename': 'photo.png' },
      payload: PNG_BYTES,
    });
    const body = upload.json();

    expect(upload.statusCode).toBe(201);
    expect(body.object_key).toMatch(new RegExp(`^${alice.id}/\\d{4}/\\d{2}/[0-9a-f-]+\\.png$`));
    expect(body.content_type).toBe('image/png');
    expect(body.size_bytes).toBe(PNG_BYTES.length);

    const { rows } = await harness.db.query<{ size_bytes: string; original_name: string }>(
      `SELECT size_bytes, original_name FROM media_objects WHERE object_key = $1`,
      [body.object_key],
    );
    expect(rows[0]!.size_bytes).toBe(String(PNG_BYTES.length));
    expect(rows[0]!.original_name).toBe('photo.png');

    const download = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/media/${body.object_key}`,
      headers: auth(alice),
    });

    expect(download.statusCode).toBe(200);
    expect(download.headers['content-type']).toBe('image/png');
    expect(download.headers['cache-control']).toBe('private, max-age=300');
    expect(download.headers.location).toBeUndefined();
    expect(download.rawPayload.equals(PNG_BYTES)).toBe(true);
  });

  it('derives the extension when no filename is supplied', async () => {
    const alice = await registerUser(harness, 'Alice');

    const upload = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'application/pdf' },
      payload: Buffer.from('%PDF-1.4'),
    });

    expect(upload.statusCode).toBe(201);
    expect(upload.json().object_key).toMatch(/\.pdf$/);
  });

  it('rejects an unsupported content type', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'application/x-msdownload' },
      payload: Buffer.from('MZ'),
    });

    expect(response.statusCode).toBe(415);
    expect(response.json().error.code).toBe('unsupported_media_type');
  });

  it('rejects an empty body and a missing token', async () => {
    const alice = await registerUser(harness, 'Alice');

    const empty = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'image/png' },
      payload: Buffer.alloc(0),
    });
    const anonymous = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { 'content-type': 'image/png' },
      payload: PNG_BYTES,
    });

    expect(empty.statusCode).toBe(422);
    expect(empty.json().error.code).toBe('validation_error');
    expect(anonymous.statusCode).toBe(401);
  });

  it('limits proxied downloads to users who can see the media', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    const eve = await registerUser(harness, 'Eve');
    await createDirect(harness, alice, bob);

    const upload = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/media/upload',
      headers: { ...auth(alice), 'content-type': 'image/png' },
      payload: PNG_BYTES,
    });
    const key = upload.json().object_key as string;

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

    expect(partner.statusCode).toBe(200);
    expect(stranger.statusCode).toBe(403);
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
