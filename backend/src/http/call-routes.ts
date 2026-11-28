import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

const startCallSchema = z.object({
  media_type: z.enum(['voice', 'video']),
});

const rejectCallSchema = z
  .object({
    reason: z.enum(['declined', 'busy']).default('declined'),
  })
  .optional()
  .transform((value) => value ?? { reason: 'declined' as const });

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

function requireUuid(value: string, what: string): string {
  if (!isUuid(value)) {
    throw new ApiError('validation_error', `${what} must be a UUID`);
  }
  return value;
}

export function registerCallRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, callSignaling } = ctx;

  app.post('/api/v1/conversations/:id/calls', async (request, reply) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    const conversationId = requireUuid(id, 'Conversation id');
    const body = parse(startCallSchema, request.body);

    const result = await callSignaling.startCall({
      conversationId,
      callerId: request.userId,
      deviceId: request.deviceId,
      mediaType: body.media_type,
    });
    reply.status(result.joined_existing ? 200 : 201).send(result);
  });

  app.post('/api/v1/calls/:callId/accept', async (request) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    return callSignaling.acceptCall({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
      deviceId: request.deviceId,
    });
  });

  app.post('/api/v1/calls/:callId/join', async (request) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    return callSignaling.joinGroupCall({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
      deviceId: request.deviceId,
    });
  });

  app.post('/api/v1/calls/:callId/token', async (request) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    return callSignaling.refreshToken({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
      deviceId: request.deviceId,
    });
  });

  app.post('/api/v1/calls/:callId/reject', async (request, reply) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    const body = parse(rejectCallSchema, request.body ?? {});
    await callSignaling.rejectCall({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
      deviceId: request.deviceId,
      reason: body.reason,
    });
    reply.status(204).send();
  });

  app.post('/api/v1/calls/:callId/cancel', async (request, reply) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    await callSignaling.cancelCall({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
    });
    reply.status(204).send();
  });

  app.post('/api/v1/calls/:callId/leave', async (request, reply) => {
    requireAuth(request, config);
    const { callId } = request.params as { callId: string };
    await callSignaling.leaveCall({
      callId: requireUuid(callId, 'Call id'),
      userId: request.userId,
    });
    reply.status(204).send();
  });

  app.get('/api/v1/conversations/:id/active-call', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    const active = await callSignaling.getActiveCallForConversation(
      requireUuid(id, 'Conversation id'),
      request.userId,
    );
    return { active_call: active };
  });

  app.get('/api/v1/calls/active', async (request) => {
    requireAuth(request, config);
    const calls = await callSignaling.listActiveCallsForUser(request.userId);
    return { calls };
  });

  // Encapsulated plugin so raw-string body parsing applies ONLY to LiveKit webhooks,
  // preserving the exact bytes LiveKit hashes in its Authorization JWT signature.
  app.register(async (webhookApp) => {
    webhookApp.removeAllContentTypeParsers();
    webhookApp.addContentTypeParser(
      ['application/webhook+json', 'application/json'],
      { parseAs: 'string' },
      (_request, body, done) => {
        done(null, typeof body === 'string' ? body : body.toString('utf8'));
      },
    );

    webhookApp.post('/api/v1/webhooks/livekit', async (request) => {
      const rawBody = typeof request.body === 'string' ? request.body : '';
      const authHeader =
        typeof request.headers.authorization === 'string' ? request.headers.authorization : '';
      await callSignaling.handleWebhook(rawBody, authHeader);
      return { ok: true };
    });
  });
}
