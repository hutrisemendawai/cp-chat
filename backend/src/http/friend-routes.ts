import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';
import { toFriendUser } from '../domain/friends.js';

const addSchema = z
  .object({
    identifier: z.string().trim().min(1).max(200).optional(),
    user_id: z.string().trim().min(1).optional(),
  })
  .refine((value) => value.identifier !== undefined || value.user_id !== undefined, {
    message: 'Provide an identifier or a user_id',
  });

export function registerFriendRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, friends, presence, users } = ctx;

  /** The caller's friends, online users first, each with live presence. */
  app.get('/api/v1/friends', async (request) => {
    requireAuth(request, config);
    return { friends: await friends.list(request.userId) };
  });

  /**
   * Adds a friend. Accepts either an `identifier` (email/phone or exact name)
   * or a `user_id` from a search result. The insert is idempotent, so adding an
   * existing friend succeeds rather than failing.
   */
  app.post('/api/v1/friends', async (request, reply) => {
    requireAuth(request, config);
    const result = addSchema.safeParse(request.body);
    if (!result.success) {
      throw new ApiError('validation_error', 'Request failed validation', {
        issues: result.error.issues.map((issue) => ({
          path: issue.path.join('.'),
          message: issue.message,
        })),
      });
    }

    const { identifier, user_id } = result.data;
    const target = user_id
      ? await users.findById(validateUuid(user_id))
      : await friends.resolve(identifier!);
    if (!target) throw new ApiError('not_found', 'No user matches that identifier');
    if (target.id === request.userId) {
      throw new ApiError('validation_error', 'You cannot add yourself as a friend');
    }

    await friends.add(request.userId, target.id);
    const online = await presence.onlineUserIds([target.id]);
    reply.status(201).send(toFriendUser({ ...target, is_friend: true }, online.has(target.id)));
  });

  app.delete('/api/v1/friends/:friendId', async (request, reply) => {
    requireAuth(request, config);
    const { friendId } = request.params as { friendId: string };
    await friends.remove(request.userId, validateUuid(friendId));
    reply.status(204).send();
  });

  function validateUuid(value: string): string {
    if (!isUuid(value)) throw new ApiError('validation_error', 'User id must be a UUID');
    return value;
  }
}
