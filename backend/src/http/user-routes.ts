import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';
import { toPublicUser } from '../domain/users.js';

const deviceSchema = z.object({
  fcm_token: z.string().trim().min(1).max(4096),
  device_id: z.string().trim().min(1).max(200).optional(),
});

export function registerUserRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, users, devices } = ctx;

  app.get('/api/v1/users/me', async (request) => {
    requireAuth(request, config);
    const user = await users.findById(request.userId);
    if (!user) throw new ApiError('unauthorized', 'User no longer exists');
    return toPublicUser(user, true);
  });

  app.get('/api/v1/users/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) throw new ApiError('validation_error', 'User id must be a UUID');
    const user = await users.findById(id);
    if (!user) throw new ApiError('not_found', 'User not found');
    return toPublicUser(user);
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
}
