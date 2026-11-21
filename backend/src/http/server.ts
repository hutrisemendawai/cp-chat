import Fastify, { type FastifyInstance, type FastifyBaseLogger } from 'fastify';

import type { AppContext } from './context.js';
import { sendError } from './context.js';
import { registerAuthRoutes } from './auth-routes.js';
import { registerConversationRoutes } from './conversation-routes.js';
import { registerMediaRoutes } from './media-routes.js';
import { registerMessageRoutes } from './message-routes.js';
import { registerPresenceRoutes } from './presence-routes.js';
import { registerSearchRoutes } from './search-routes.js';
import { registerUserRoutes } from './user-routes.js';
import type { Logger } from '../lib/logger.js';
import { ApiError } from '../lib/errors.js';

export function buildServer(ctx: AppContext, logger: Logger): FastifyInstance {
  const app = Fastify({
    loggerInstance: logger as unknown as FastifyBaseLogger,
    trustProxy: true,
    bodyLimit: 1024 * 1024,
  });

  app.addHook('onRequest', (request, _reply, done) => {
    request.userId = '';
    request.deviceId = '';
    done();
  });

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) {
      sendError(reply, error);
      return;
    }
    if ((error as { statusCode?: number }).statusCode === 400) {
      reply.status(422).send({
        error: { code: 'validation_error', message: 'Malformed request body' },
      });
      return;
    }
    request.log.error({ err: error }, 'Unhandled request error');
    sendError(reply, error);
  });

  app.setNotFoundHandler((_request, reply) => {
    reply.status(404).send({
      error: { code: 'not_found', message: 'Route not found' },
    });
  });

  app.get('/healthz', async () => ({ status: 'ok' }));

  registerAuthRoutes(app, ctx);
  registerUserRoutes(app, ctx);
  registerConversationRoutes(app, ctx);
  registerMessageRoutes(app, ctx);
  registerMediaRoutes(app, ctx);
  registerSearchRoutes(app, ctx);
  registerPresenceRoutes(app, ctx);

  return app;
}
