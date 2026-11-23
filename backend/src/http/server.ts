import Fastify, { type FastifyInstance, type FastifyBaseLogger } from 'fastify';

import type { AppContext } from './context.js';
import { sendError } from './context.js';
import { registerAuthRoutes } from './auth-routes.js';
import { registerConversationRoutes } from './conversation-routes.js';
import { registerFriendRoutes } from './friend-routes.js';
import { registerKeyRoutes } from './key-routes.js';
import { registerLogRoutes } from './log-routes.js';
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
    // The `onResponse` hook below emits one enriched entry per request; Fastify's
    // own "incoming request"/"request completed" pair would duplicate it in the
    // shared timeline and split the fields across two entries.
    disableRequestLogging: true,
  });

  app.addHook('onRequest', (request, _reply, done) => {
    request.userId = '';
    request.deviceId = '';
    request.startTime = process.hrtime.bigint();
    done();
  });

  // One structured line per completed request. It carries the fields the log
  // buffer indexes on (method, path, status, duration, user) so the dashboard
  // can filter without parsing the message. Streaming endpoints are skipped:
  // their "completion" is the connection closing and would be noise.
  app.addHook('onResponse', (request, reply, done) => {
    if (!isStreamingPath(request.url)) {
      request.log.info(
        {
          method: request.method,
          path: request.url.split('?')[0],
          status_code: reply.statusCode,
          duration_ms: elapsedMs(request.startTime),
          user_id: request.userId || undefined,
        },
        'request completed',
      );
    }
    done();
  });

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) {
      sendError(reply, error);
      return;
    }
    const statusCode = (error as { statusCode?: number }).statusCode;
    if (statusCode === 400) {
      reply.status(422).send({
        error: { code: 'validation_error', message: 'Malformed request body' },
      });
      return;
    }
    // Preserve framework client errors such as the body-limit 413 so a large
    // media upload is reported as `media_too_large` rather than an internal 500.
    if (statusCode === 413) {
      reply.status(413).send({
        error: { code: 'media_too_large', message: 'File exceeds the upload limit' },
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
  registerFriendRoutes(app, ctx);
  registerConversationRoutes(app, ctx);
  registerMessageRoutes(app, ctx);
  registerMediaRoutes(app, ctx);
  registerSearchRoutes(app, ctx);
  registerPresenceRoutes(app, ctx);
  registerKeyRoutes(app, ctx);
  registerLogRoutes(app, ctx);

  return app;
}

function isStreamingPath(url: string): boolean {
  const path = url.split('?')[0];
  return path === '/api/v1/logs/stream';
}

function elapsedMs(start: number | bigint | undefined): number | undefined {
  if (typeof start !== 'bigint') return undefined;
  return Number(process.hrtime.bigint() - start) / 1_000_000;
}
