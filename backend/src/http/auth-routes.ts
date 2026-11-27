import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { hashPassword, verifyPassword } from '../lib/password.js';
import { ApiError } from '../lib/errors.js';
import { signAccessToken } from '../lib/tokens.js';
import { toPublicUser } from '../domain/users.js';

const usernameSchema = z
  .string()
  .trim()
  .min(3, 'Username must be at least 3 characters')
  .max(30, 'Username must be at most 30 characters')
  .regex(/^[a-zA-Z0-9_.]+$/, 'Username may only contain letters, numbers, "_" and "."')
  .refine((value) => !value.startsWith('.') && !value.endsWith('.'), {
    message: 'Username cannot start or end with a dot',
  })
  .refine((value) => !value.includes('..'), {
    message: 'Username cannot contain consecutive dots',
  })
  .transform((value) => value.toLowerCase());

const registerSchema = z.object({
  phone_or_email: z.string().trim().min(3).max(255),
  username: usernameSchema,
  name: z.string().trim().min(1).max(100),
  password: z.string().min(8).max(200),
});

const loginSchema = z
  .object({
    identifier: z.string().trim().min(1).optional(),
    phone_or_email: z.string().trim().min(1).optional(),
    password: z.string().min(1),
    device_id: z.string().trim().min(1).max(200).optional(),
  })
  .refine((value) => value.identifier !== undefined || value.phone_or_email !== undefined, {
    message: 'Provide an identifier (email or username)',
  });

const refreshSchema = z.object({
  refresh_token: z.string().min(1),
  device_id: z.string().trim().min(1).max(200).optional(),
});

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw new ApiError('validation_error', 'Request failed validation', {
      issues: result.error.issues.map((issue) => ({
        path: issue.path.join('.'),
        message: issue.message,
      })),
    });
  }
  return result.data;
}

function deviceIdFrom(request: { headers: Record<string, unknown> }, fallback?: string) {
  const header = request.headers['x-device-id'];
  if (fallback) return fallback;
  return typeof header === 'string' && header.length > 0 ? header : null;
}

export function registerAuthRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, users, refreshTokens } = ctx;

  // Verified against for unknown accounts so a failed login costs the same
  // scrypt work whether or not the account exists.
  let decoyHash: Promise<string> | null = null;
  const getDecoyHash = () => (decoyHash ??= hashPassword('decoy-password-not-used'));

  const issue = async (userId: string, deviceId: string | null) => {
    const refresh = await refreshTokens.issue(userId, deviceId);
    return {
      accessToken: signAccessToken(userId, deviceId ?? 'unknown', config),
      refreshToken: refresh.token,
    };
  };

  app.post('/api/v1/auth/register', async (request, reply) => {
    const input = parse(registerSchema, request.body);
    if (await users.findByContact(input.phone_or_email)) {
      throw new ApiError('conflict', 'That phone number or email is already registered');
    }
    if (await users.findByUsername(input.username)) {
      throw new ApiError('conflict', 'Username is already taken');
    }

    const passwordHash = await hashPassword(input.password);
    let user;
    try {
      user = await users.create({
        username: input.username,
        phoneOrEmail: input.phone_or_email,
        name: input.name,
        passwordHash,
      });
    } catch (error) {
      // Unique violation from a concurrent registration of the same contact or
      // username. The index name distinguishes which one collided.
      if ((error as { code?: string }).code === '23505') {
        const constraint = (error as { constraint?: string }).constraint ?? '';
        if (constraint.includes('username')) {
          throw new ApiError('conflict', 'Username is already taken');
        }
        throw new ApiError('conflict', 'That phone number or email is already registered');
      }
      throw error;
    }

    const deviceId = deviceIdFrom(request);
    const tokens = await issue(user.id, deviceId);

    reply.status(201).send({
      user: toPublicUser(user, true),
      access_token: tokens.accessToken,
      refresh_token: tokens.refreshToken,
      expires_in: config.ACCESS_TOKEN_TTL_SECONDS,
    });
  });

  app.post('/api/v1/auth/login', async (request, reply) => {
    const input = parse(loginSchema, request.body);
    const deviceId = deviceIdFrom(request, input.device_id);
    const identifier = input.identifier ?? input.phone_or_email!;
    const user = await users.findByIdentifier(identifier);

    const valid = await verifyPassword(input.password, user?.password_hash ?? (await getDecoyHash()));
    if (!user || !valid) {
      throw new ApiError('invalid_credentials', 'Incorrect email/username or password');
    }

    const tokens = await issue(user.id, deviceId);
    reply.status(200).send({
      user: toPublicUser(user, true),
      access_token: tokens.accessToken,
      refresh_token: tokens.refreshToken,
      expires_in: config.ACCESS_TOKEN_TTL_SECONDS,
    });
  });

  app.post('/api/v1/auth/refresh', async (request, reply) => {
    const input = parse(refreshSchema, request.body);
    const deviceId = deviceIdFrom(request, input.device_id);

    const rotated = await refreshTokens.rotate(input.refresh_token, deviceId);
    reply.status(200).send({
      access_token: signAccessToken(rotated.userId, deviceId ?? 'unknown', config),
      refresh_token: rotated.token,
      expires_in: config.ACCESS_TOKEN_TTL_SECONDS,
    });
  });

  app.post('/api/v1/auth/logout', async (request, reply) => {
    const input = parse(refreshSchema, request.body);
    const revoked = await refreshTokens.revoke(input.refresh_token);
    if (revoked) {
      const requestDeviceId = deviceIdFrom(request, input.device_id);
      const deviceIds = [revoked.deviceId, requestDeviceId].filter(
        (value): value is string => typeof value === 'string' && value.length > 0,
      );
      if (deviceIds.length > 0) {
        await ctx.devices.unregisterMatching(revoked.userId, { deviceIds });
      }
    }
    reply.status(204).send();
  });
}
