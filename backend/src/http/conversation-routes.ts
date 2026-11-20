import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

const createSchema = z.object({
  type: z.enum(['direct', 'group']),
  name: z.string().trim().max(100).optional(),
  member_ids: z.array(z.string()).min(1).max(499),
});

const listQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(50),
  before: z.string().optional(),
});

function parse<T>(schema: z.ZodType<T>, body: unknown, message = 'Request failed validation'): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw new ApiError('validation_error', message, {
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

export function registerConversationRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, conversations, users } = ctx;

  app.get('/api/v1/conversations', async (request) => {
    requireAuth(request, config);
    const query = parse(listQuery, request.query);
    const page = await conversations.list(request.userId, query.limit, query.before);
    return {
      conversations: page.conversations,
      next_cursor: page.nextCursor,
    };
  });

  app.post('/api/v1/conversations', async (request, reply) => {
    requireAuth(request, config);
    const input = parse(createSchema, request.body);

    const memberIds = [...new Set(input.member_ids.map((id) => requireUuid(id, 'member_ids')))];
    if (memberIds.includes(request.userId)) {
      throw new ApiError('validation_error', 'member_ids must not include the caller');
    }

    if (input.type === 'group') {
      throw new ApiError(
        'unsupported_conversation_type',
        'Group conversations arrive in Phase 2',
      );
    }

    if (memberIds.length !== 1) {
      throw new ApiError('validation_error', 'A direct conversation requires exactly one member');
    }
    const otherId = memberIds[0]!;
    if (!(await users.findById(otherId))) {
      throw new ApiError('not_found', 'User not found');
    }

    const conversation = await conversations.findOrCreateDirect(request.userId, otherId);
    const summary = await conversations.getSummary(conversation.id, request.userId);
    reply.status(201).send(summary);
  });

  app.get('/api/v1/conversations/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    return conversations.getSummary(requireUuid(id, 'Conversation id'), request.userId);
  });
}
