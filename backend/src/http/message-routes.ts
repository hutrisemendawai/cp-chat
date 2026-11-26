import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

const pageQuery = z.object({
  before_seq: z.coerce.number().int().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});

const syncQuery = z.object({
  after_seq: z.coerce.number().int().min(0).default(0),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

function parse<T>(schema: z.ZodType<T>, value: unknown): T {
  const result = schema.safeParse(value);
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

export function registerMessageRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, conversations, messages } = ctx;

  const conversationId = (id: string) => {
    if (!isUuid(id)) throw new ApiError('validation_error', 'Conversation id must be a UUID');
    return id;
  };

  app.get('/api/v1/conversations/:id/messages', async (request) => {
    requireAuth(request, config);
    const params = request.params as { id: string };
    const query = parse(pageQuery, request.query);
    const id = conversationId(params.id);

    const conversation = await conversations.requireMemberConversation(id, request.userId);
    const page = await messages.page(id, query.limit, query.before_seq, conversation.cleared_seq);
    return {
      messages: page.messages,
      has_more: page.hasMore,
      cleared_seq: conversation.cleared_seq,
    };
  });

  app.get('/api/v1/conversations/:id/sync', async (request) => {
    requireAuth(request, config);
    const params = request.params as { id: string };
    const query = parse(syncQuery, request.query);
    const id = conversationId(params.id);

    const conversation = await conversations.requireMemberConversation(id, request.userId);
    const result = await messages.sync(id, query.after_seq, query.limit, conversation.cleared_seq);
    return {
      messages: result.messages,
      latest_seq: result.latestSeq,
      cleared_seq: result.clearedSeq,
    };
  });
}
