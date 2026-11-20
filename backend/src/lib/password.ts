import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

type ScryptOptions = { N: number; r: number; p: number };
type ScryptFn = (
  password: string,
  salt: Buffer,
  keylen: number,
  options: ScryptOptions,
) => Promise<Buffer>;

const scrypt = promisify(scryptCallback) as unknown as ScryptFn;

const KEY_LENGTH = 64;
const SCRYPT_COST: ScryptOptions = { N: 16384, r: 8, p: 1 };

/** scrypt with a per-password salt, stored as `scrypt$N$r$p$salt$hash`. */
export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const derived = await scrypt(password, salt, KEY_LENGTH, SCRYPT_COST);
  return [
    'scrypt',
    SCRYPT_COST.N,
    SCRYPT_COST.r,
    SCRYPT_COST.p,
    salt.toString('base64'),
    derived.toString('base64'),
  ].join('$');
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [scheme, n, r, p, salt, hash] = stored.split('$');
  if (scheme !== 'scrypt' || !salt || !hash) return false;

  const expected = Buffer.from(hash, 'base64');
  const derived = await scrypt(password, Buffer.from(salt, 'base64'), expected.length, {
    N: Number(n),
    r: Number(r),
    p: Number(p),
  });

  return derived.length === expected.length && timingSafeEqual(derived, expected);
}
