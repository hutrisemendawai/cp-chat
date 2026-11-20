import { describe, expect, it } from 'vitest';

import { ApiError } from '../src/lib/errors.js';
import { directKey, isUuid, isUuidV4 } from '../src/lib/ids.js';
import { hashPassword, verifyPassword } from '../src/lib/password.js';
import {
  generateRefreshToken,
  hashRefreshToken,
  signAccessToken,
  verifyAccessToken,
} from '../src/lib/tokens.js';
import { TEST_CONFIG } from './helpers.js';

describe('password hashing', () => {
  it('verifies the right password and rejects the wrong one', async () => {
    const hash = await hashPassword('correct horse battery staple');

    expect(hash.startsWith('scrypt$')).toBe(true);
    expect(await verifyPassword('correct horse battery staple', hash)).toBe(true);
    expect(await verifyPassword('wrong', hash)).toBe(false);
  });

  it('produces a different hash for the same password', async () => {
    const first = await hashPassword('same-password');
    const second = await hashPassword('same-password');

    expect(first).not.toBe(second);
    expect(await verifyPassword('same-password', first)).toBe(true);
    expect(await verifyPassword('same-password', second)).toBe(true);
  });

  it('rejects a malformed stored hash instead of throwing', async () => {
    expect(await verifyPassword('x', 'not-a-hash')).toBe(false);
    expect(await verifyPassword('x', 'bcrypt$1$2$3$4$5')).toBe(false);
  });
});

describe('access tokens', () => {
  it('round-trips the user and device claims', () => {
    const token = signAccessToken('user-1', 'device-9', TEST_CONFIG);
    const payload = verifyAccessToken(token, TEST_CONFIG);

    expect(payload.sub).toBe('user-1');
    expect(payload.device_id).toBe('device-9');
    expect(payload.type).toBe('access');
  });

  it('rejects a token signed with another secret', () => {
    const token = signAccessToken('user-1', 'device-9', {
      ...TEST_CONFIG,
      JWT_SECRET: 'a-completely-different-secret-value',
    });

    expect(() => verifyAccessToken(token, TEST_CONFIG)).toThrow(ApiError);
  });

  it('rejects a tampered token', () => {
    const token = signAccessToken('user-1', 'device-9', TEST_CONFIG);
    const [header, payload, signature] = token.split('.');
    const tampered = `${header}.${payload}.${signature?.slice(0, -2)}xx`;

    expect(() => verifyAccessToken(tampered, TEST_CONFIG)).toThrow(ApiError);
  });

  it('rejects garbage', () => {
    expect(() => verifyAccessToken('not.a.token', TEST_CONFIG)).toThrow(ApiError);
  });
});

describe('refresh tokens', () => {
  it('generates an opaque token with a stable hash', () => {
    const { token, hash } = generateRefreshToken();

    expect(token.length).toBeGreaterThan(30);
    expect(hash).toBe(hashRefreshToken(token));
    expect(hash).toHaveLength(64);
    expect(token).not.toContain(hash);
  });

  it('never repeats', () => {
    const tokens = new Set(Array.from({ length: 50 }, () => generateRefreshToken().token));
    expect(tokens.size).toBe(50);
  });
});

describe('ids', () => {
  it('orders a direct key deterministically', () => {
    expect(directKey('b', 'a')).toBe('a:b');
    expect(directKey('a', 'b')).toBe('a:b');
    expect(directKey('a', 'a')).toBe('a:a');
  });

  it('validates UUIDs', () => {
    expect(isUuid('2f40ffbe-0738-4d45-92d2-3249db6b11de')).toBe(true);
    expect(isUuid('not-a-uuid')).toBe(false);
    expect(isUuid('')).toBe(false);
  });

  it('only accepts v4 for client message ids', () => {
    expect(isUuidV4('2f40ffbe-0738-4d45-92d2-3249db6b11de')).toBe(true);
    expect(isUuidV4('2f40ffbe-0738-1d45-92d2-3249db6b11de')).toBe(false);
  });
});

describe('errors', () => {
  it('maps codes to HTTP statuses and an error envelope', () => {
    const error = new ApiError('not_a_member', 'no access', { conversation: 'c1' });

    expect(error.status).toBe(403);
    expect(error.toBody()).toEqual({
      error: { code: 'not_a_member', message: 'no access', details: { conversation: 'c1' } },
    });
  });

  it('omits details when none are supplied', () => {
    expect(new ApiError('not_found', 'gone').toBody()).toEqual({
      error: { code: 'not_found', message: 'gone' },
    });
  });
});
