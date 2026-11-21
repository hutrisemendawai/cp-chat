import type { FastifyInstance } from 'fastify';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

export function registerPresenceRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, presence } = ctx;

  /**
   * Current presence for one user, used by chat headers on open. Live changes
   * afterwards arrive as `presence` frames on the WebSocket.
   */
  app.get('/api/v1/presence/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) throw new ApiError('validation_error', 'User id must be a UUID');

    const snapshot = await presence.snapshot(id);
    if (!snapshot) throw new ApiError('not_found', 'User not found');
    return snapshot;
  });
}
