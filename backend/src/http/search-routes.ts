import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

const searchQuery = z.object({
  q: z.string().trim().min(1).max(200),
  limit: z.coerce.number().int().min(1).max(100).default(30),
  before_seq: z.coerce.number().int().min(1).optional(),
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

export function registerSearchRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, conversations, messages } = ctx;

  /** Global search across every conversation the caller belongs to. */
  app.get('/api/v1/search', async (request) => {
    requireAuth(request, config);
    const query = parse(searchQuery, request.query);

    const result = await messages.search({
      userId: request.userId,
      query: query.q,
      limit: query.limit,
      beforeSeq: query.before_seq,
    });

    return { messages: result.messages, has_more: result.hasMore };
  });

  /** In-chat search, scoped to a conversation the caller is a member of. */
  app.get('/api/v1/conversations/:id/search', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) throw new ApiError('validation_error', 'Conversation id must be a UUID');

    const query = parse(searchQuery, request.query);
    await conversations.requireMemberConversation(id, request.userId);

    const result = await messages.search({
      userId: request.userId,
      query: query.q,
      conversationId: id,
      limit: query.limit,
      beforeSeq: query.before_seq,
    });

    return { messages: result.messages, has_more: result.hasMore };
  });
}
