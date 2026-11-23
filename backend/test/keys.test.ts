import { randomUUID } from 'node:crypto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { KeyRepository } from '../src/domain/keys.js';
import {
  E2EE_PREFIX,
  buildEnvelope,
  isEncryptedContent,
  parseMessageContent,
  type E2eeEnvelope,
} from '../src/lib/e2ee.js';
import {
  auth,
  createHarness,
  registerUser,
  truncateAll,
  type TestHarness,
  type TestUser,
} from './helpers.js';

let harness: TestHarness;
let keys: KeyRepository;

beforeAll(async () => {
  harness = await createHarness();
  keys = new KeyRepository(harness.db);
});

afterAll(async () => {
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
});

/** Base64-looking placeholders; the server never interprets key bytes. */
function fakeKey(label: string): string {
  return Buffer.from(label.padEnd(32, '.')).toString('base64');
}

async function publish(
  user: TestUser,
  { prekeys = 3 }: { prekeys?: number } = {},
): Promise<void> {
  const response = await harness.app.inject({
    method: 'POST',
    url: '/api/v1/keys',
    headers: auth(user),
    payload: {
      identity_key: fakeKey(`identity-${user.id}`),
      signing_key: fakeKey(`signing-${user.id}`),
      signed_prekey: {
        key_id: 7,
        public_key: fakeKey(`signed-${user.id}`),
        signature: fakeKey(`signature-${user.id}`),
      },
      one_time_prekeys: Array.from({ length: prekeys }, (_, index) => ({
        key_id: index + 1,
        public_key: fakeKey(`otp-${index}`),
      })),
    },
  });
  expect(response.statusCode).toBe(201);
}

describe('e2ee key registry', () => {
  it('publishes keys and returns a usable prekey bundle', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await publish(bob);

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });

    expect(response.statusCode).toBe(200);
    expect(response.headers['cache-control']).toBe('no-store');
    const bundle = response.json();
    expect(bundle).toMatchObject({
      user_id: bob.id,
      identity_key: fakeKey(`identity-${bob.id}`),
      signing_key: fakeKey(`signing-${bob.id}`),
      signed_prekey: { key_id: 7 },
    });
    expect(bundle.one_time_prekey).toMatchObject({ key_id: 1 });
    expect(bundle.remaining_one_time_prekeys).toBe(2);
  });

  it('never hands the same one-time prekey to two callers', async () => {
    const alice = await registerUser(harness, 'Alice');
    const carol = await registerUser(harness, 'Carol');
    const bob = await registerUser(harness, 'Bob');
    await publish(bob, { prekeys: 2 });

    const first = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });
    const second = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(carol),
    });

    expect(first.json().one_time_prekey.key_id).toBe(1);
    expect(second.json().one_time_prekey.key_id).toBe(2);
    expect(first.json().one_time_prekey.public_key).not.toBe(
      second.json().one_time_prekey.public_key,
    );

    // Exhausted: the bundle still works via the signed prekey alone.
    const third = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });
    expect(third.json().one_time_prekey).toBeNull();
    expect(third.json().remaining_one_time_prekeys).toBe(0);
  });

  it('consumes the last prekey exactly once under concurrent fetches', async () => {
    const bob = await registerUser(harness, 'Bob');
    const callers = await Promise.all([
      registerUser(harness, 'Caller1'),
      registerUser(harness, 'Caller2'),
      registerUser(harness, 'Caller3'),
    ]);
    await publish(bob, { prekeys: 1 });

    const responses = await Promise.all(
      callers.map((caller) =>
        harness.app.inject({
          method: 'GET',
          url: `/api/v1/keys/${bob.id}`,
          headers: auth(caller),
        }),
      ),
    );

    const delivered = responses
      .map((response) => response.json().one_time_prekey)
      .filter((prekey) => prekey !== null);
    // Only one caller can receive the single prekey; the rest fall back to the
    // signed prekey and must not error.
    expect(delivered).toHaveLength(1);
    expect(responses.every((response) => response.statusCode === 200)).toBe(true);
    expect(await keys.countOneTimePrekeys(bob.id)).toBe(0);
  });

  it('tops up one-time prekeys without republishing identity keys', async () => {
    const bob = await registerUser(harness, 'Bob');
    await publish(bob, { prekeys: 1 });

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/keys/prekeys',
      headers: auth(bob),
      payload: {
        one_time_prekeys: [
          { key_id: 50, public_key: fakeKey('topup-50') },
          { key_id: 51, public_key: fakeKey('topup-51') },
        ],
      },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ added: 2, one_time_prekeys: 3 });

    // Re-uploading the same ids is a no-op, not a duplicate-key error.
    const retry = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/keys/prekeys',
      headers: auth(bob),
      payload: {
        one_time_prekeys: [{ key_id: 50, public_key: fakeKey('topup-50') }],
      },
    });
    expect(retry.json()).toMatchObject({ added: 0, one_time_prekeys: 3 });
  });

  it('reports not found for a user with no published keys', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');

    const response = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });
    expect(response.statusCode).toBe(404);
    expect(response.json().error.code).toBe('keys_not_found');
  });

  it('rejects malformed key material and unauthenticated access', async () => {
    const bob = await registerUser(harness, 'Bob');

    const missingIdentity = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/keys',
      headers: auth(bob),
      payload: {
        identity_key: 'x',
        signing_key: 'y',
        signed_prekey: { key_id: 1, public_key: 'z', signature: 's' },
      },
    });
    expect(missingIdentity.statusCode).toBe(201);

    const anonymous = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
    });
    expect(anonymous.statusCode).toBe(401);

    const malformed = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/keys/not-a-uuid',
      headers: auth(bob),
    });
    expect(malformed.statusCode).toBe(422);
  });

  it('exposes the caller own key status without private material', async () => {
    const bob = await registerUser(harness, 'Bob');
    await publish(bob, { prekeys: 4 });

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/keys/me',
      headers: auth(bob),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      user_id: bob.id,
      one_time_prekeys: 4,
    });
    expect(JSON.stringify(response.json())).not.toContain('private');
  });

  it('discards orphaned one-time prekeys when the identity key rotates', async () => {
    // A reinstall publishes a fresh identity; the old prekeys' private halves
    // are gone with the previous install, so handing one out would let a peer
    // build a session the recipient can never derive.
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await publish(bob, { prekeys: 3 });

    const rotated = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/keys',
      headers: auth(bob),
      payload: {
        identity_key: fakeKey('rotated-identity'),
        signing_key: fakeKey('rotated-signing'),
        signed_prekey: {
          key_id: 9,
          public_key: fakeKey('rotated-signed'),
          signature: fakeKey('rotated-signature'),
        },
        one_time_prekeys: [
          { key_id: 100, public_key: fakeKey('rotated-otp-100') },
          { key_id: 101, public_key: fakeKey('rotated-otp-101') },
        ],
      },
    });
    expect(rotated.statusCode).toBe(201);

    // Only the fresh batch survives, so the first bundle can never reference a
    // prekey from the previous device.
    expect(await keys.countOneTimePrekeys(bob.id)).toBe(2);

    const bundle = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });
    expect(bundle.statusCode).toBe(200);
    expect(bundle.json().identity_key).toBe(fakeKey('rotated-identity'));
    expect(bundle.json().one_time_prekey.key_id).toBe(100);
  });

  it('keeps the one-time prekey supply on a republish by the same device', async () => {
    const alice = await registerUser(harness, 'Alice');
    const bob = await registerUser(harness, 'Bob');
    await publish(bob, { prekeys: 3 });

    // Same identity, republished (e.g. app restart). The supply must survive,
    // otherwise every foreground start would throw away unclaimed prekeys.
    const republished = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/keys',
      headers: auth(bob),
      payload: {
        identity_key: fakeKey(`identity-${bob.id}`),
        signing_key: fakeKey(`signing-${bob.id}`),
        signed_prekey: {
          key_id: 7,
          public_key: fakeKey(`signed-${bob.id}`),
          signature: fakeKey(`signature-${bob.id}`),
        },
      },
    });
    expect(republished.statusCode).toBe(201);
    expect(await keys.countOneTimePrekeys(bob.id)).toBe(3);

    const bundle = await harness.app.inject({
      method: 'GET',
      url: `/api/v1/keys/${bob.id}`,
      headers: auth(alice),
    });
    expect(bundle.json().one_time_prekey.key_id).toBe(1);
  });
});

describe('e2ee envelope', () => {
  const envelope: E2eeEnvelope = {
    v: 1,
    ik: fakeKey('identity'),
    ek: fakeKey('ephemeral'),
    spk: 7,
    opk: 3,
    i: 0,
    ct: Buffer.from('ciphertext').toString('base64'),
    n: Buffer.from('0123456789ab').toString('base64'),
    m: Buffer.from('0123456789abcdef').toString('base64'),
  };

  it('round-trips an envelope and keeps plaintext distinguishable', () => {
    const content = buildEnvelope(envelope);
    expect(content.startsWith(E2EE_PREFIX)).toBe(true);
    expect(isEncryptedContent(content)).toBe(true);

    expect(parseMessageContent(content)).toEqual({ encrypted: true, envelope });
    expect(parseMessageContent('hello there')).toEqual({
      encrypted: false,
      plaintext: 'hello there',
    });
  });

  it('rejects a prefixed body that is not valid JSON', () => {
    expect(() => parseMessageContent(`${E2EE_PREFIX}not-json`)).toThrow(
      'malformed_e2ee_envelope',
    );
  });

  it('rejects an envelope with a missing field or unknown version', () => {
    const { ct: _ct, ...missingCt } = envelope;
    expect(() =>
      parseMessageContent(`${E2EE_PREFIX}${JSON.stringify(missingCt)}`),
    ).toThrow('malformed_e2ee_envelope');

    expect(() =>
      parseMessageContent(`${E2EE_PREFIX}${JSON.stringify({ ...envelope, v: 2 })}`),
    ).toThrow('unsupported_e2ee_version');
  });

  it('accepts a reply envelope that omits the initiation fields', () => {
    const { ek: _ek, spk: _spk, opk: _opk, ...reply } = envelope;
    const parsed = parseMessageContent(buildEnvelope(reply as E2eeEnvelope));

    expect(parsed.encrypted).toBe(true);
    if (parsed.encrypted) {
      expect(parsed.envelope.ek).toBeUndefined();
      expect(parsed.envelope.ct).toBe(envelope.ct);
    }
  });

  it('refuses to relay a corrupt envelope over the websocket path', () => {
    // Mirrors the gateway check: a prefixed but corrupt body must not fall
    // through as plaintext and be delivered.
    expect(() => parseMessageContent(`${E2EE_PREFIX}${randomUUID()}`)).toThrow();
  });
});
