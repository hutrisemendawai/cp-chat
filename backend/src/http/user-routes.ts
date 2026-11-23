import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';
import { USER_STATUSES, toOwnUser, toPublicUser } from '../domain/users.js';

const deviceSchema = z.object({
  fcm_token: z.string().trim().min(1).max(4096),
  device_id: z.string().trim().min(1).max(200).optional(),
});

const profileSchema = z
  .object({
    name: z.string().trim().min(1).max(100).optional(),
    nickname: z.string().trim().max(60).nullable().optional(),
    avatar_url: z.string().trim().max(2048).nullable().optional(),
    status: z.enum(USER_STATUSES as [string, ...string[]]).optional(),
    custom_status: z.string().trim().max(120).nullable().optional(),
    bio: z.string().trim().max(2000).nullable().optional(),
  })
  .refine((value) => Object.keys(value).length > 0, {
    message: 'Provide at least one profile field to update',
  });

const searchSchema = z.object({
  q: z.string().trim().min(1).max(100),
  limit: z.coerce.number().int().min(1).max(50).default(20),
});

export function registerUserRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, users, devices, presence, friends } = ctx;

  app.get('/api/v1/users/me', async (request) => {
    requireAuth(request, config);
    const user = await users.findById(request.userId);
    if (!user) throw new ApiError('unauthorized', 'User no longer exists');
    return toOwnUser(user, await presence.isOnline(user.id));
  });

  /**
   * Updates the caller's profile. A change to `status` (the visible presence
   * preference) or `custom_status` is pushed to every peer who shares a
   * conversation, so their badges update without a poll. A user going
   * `invisible` is broadcast as `offline`, never as an online state.
   */
  app.patch('/api/v1/users/me', async (request) => {
    requireAuth(request, config);
    const result = profileSchema.safeParse(request.body);
    if (!result.success) {
      throw new ApiError('validation_error', 'Request failed validation', {
        issues: result.error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
        })),
      });
    }

    const patch = result.data as {
      name?: string;
      nickname?: string | null;
      avatar_url?: string | null;
      status?: (typeof USER_STATUSES)[number];
      custom_status?: string | null;
      bio?: string | null;
    };

    const updated = await users.updateProfile(request.userId, patch);
    if (!updated) throw new ApiError('not_found', 'User not found');

    const presenceChanged = patch.status !== undefined || patch.custom_status !== undefined;
    if (presenceChanged) {
      await broadcastPresence(request.userId);
    }

    return toOwnUser(updated, await presence.isOnline(updated.id));
  });

  /**
   * Directory search over name and email/phone. Registered before the `:id`
   * route conceptually, but Fastify always prefers a static segment anyway.
   * The caller is excluded and each result reports whether they are already a
   * friend so the picker can render the relationship.
   */
  app.get('/api/v1/users/search', async (request) => {
    requireAuth(request, config);
    const result = searchSchema.safeParse(request.query);
    if (!result.success) {
      throw new ApiError('validation_error', 'Request failed validation', {
        issues: result.error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
        })),
      });
    }

    const { q, limit } = result.data;
    const found = await friends.search(request.userId, q.trim(), limit);
    return { users: found };
  });

  app.get('/api/v1/users/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) throw new ApiError('validation_error', 'User id must be a UUID');
    const user = await users.findById(id);
    if (!user) throw new ApiError('not_found', 'User not found');

    const snapshot = await presence.snapshot(id);
    return {
      ...toPublicUser(user),
      // Public profile is always visible to an authenticated app user so a
      // contact can be identified by email before a chat starts.
      phone_or_email: user.phone_or_email,
      effective_status: snapshot?.status ?? 'offline',
      online: snapshot?.online ?? false,
      last_seen_at: snapshot?.last_seen_at ?? user.last_seen_at,
      custom_status: snapshot?.custom_status ?? user.custom_status,
      is_friend: await friends.isFriend(request.userId, id),
    };
  });

  app.post('/api/v1/devices/fcm-token', async (request, reply) => {
    requireAuth(request, config);
    const result = deviceSchema.safeParse(request.body);
    if (!result.success) {
      throw new ApiError('validation_error', 'Request failed validation', {
        issues: result.error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
        })),
      });
    }

    const deviceId = result.data.device_id ?? request.deviceId;
    await devices.register(request.userId, deviceId, result.data.fcm_token);
    reply.status(204).send();
  });

  app.delete('/api/v1/devices/fcm-token', async (request, reply) => {
    requireAuth(request, config);
    await devices.unregister(request.userId, request.deviceId);
    reply.status(204).send();
  });

  /** Fans a presence frame to peers sharing a conversation with `userId`. */
  async function broadcastPresence(userId: string): Promise<void> {
    const snapshot = await presence.snapshot(userId);
    if (!snapshot) return;

    const peers = await presence.sharedPeerIds(userId);
    if (peers.length === 0) return;

    await ctx.broker.publishBroadcast(
      {
        user_ids: peers,
        frame: {
          type: 'presence',
          user_id: userId,
          online: snapshot.online,
          status: snapshot.status,
          custom_status: snapshot.custom_status,
          last_seen_at: snapshot.last_seen_at ? snapshot.last_seen_at.toISOString() : null,
        },
      },
      `u:${userId}`,
    );
  }
}
