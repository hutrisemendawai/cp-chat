import { createHash, randomBytes } from 'node:crypto';

import jwt from 'jsonwebtoken';

import type { Config } from '../config.js';
import { ApiError } from './errors.js';

export type AccessTokenPayload = {
  sub: string;
  device_id: string;
  type: 'access';
  iat: number;
  exp: number;
};

export function signAccessToken(
  userId: string,
  deviceId: string,
  config: Config,
): string {
  return jwt.sign({ sub: userId, device_id: deviceId, type: 'access' }, config.JWT_SECRET, {
    algorithm: 'HS256',
    expiresIn: config.ACCESS_TOKEN_TTL_SECONDS,
  });
}

export function verifyAccessToken(token: string, config: Config): AccessTokenPayload {
  try {
    const payload = jwt.verify(token, config.JWT_SECRET, {
      algorithms: ['HS256'],
    }) as jwt.JwtPayload;

    if (payload.type !== 'access' || typeof payload.sub !== 'string') {
      throw new ApiError('invalid_token', 'Not an access token');
    }
    const deviceId = payload.device_id;
    if (typeof deviceId !== 'string' || deviceId.length === 0) {
      throw new ApiError('invalid_token', 'Access token is missing a device identifier');
    }

    return {
      sub: payload.sub,
      device_id: deviceId,
      type: 'access',
      iat: payload.iat ?? 0,
      exp: payload.exp ?? 0,
    };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError('invalid_token', 'Access token is invalid or expired');
  }
}

/** Refresh tokens are opaque 256-bit values; only their hash is persisted. */
export function generateRefreshToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: hashRefreshToken(token) };
}

export function hashRefreshToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
