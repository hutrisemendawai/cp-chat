import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';
import { publishBroadcast } from '../lib/redis.js';

const createSchema = z.object({
  type: z.enum(['direct', 'group']),
  name: z.string().trim().max(100).optional(),
  avatar_url: z.string().trim().max(2048).optional(),
  member_ids: z.array(z.string()).min(1).max(499),
});

const updateSchema = z
  .object({
    name: z.string().trim().min(1).max(100).optional(),
    avatar_url: z.string().trim().max(2048).nullable().optional(),
  })
  .refine((value) => value.name !== undefined || value.avatar_url !== undefined, {
    message: 'Provide a name or avatar_url to update',
  });

const addMembersSchema = z.object({
  user_ids: z.array(z.string()).min(1).max(499),
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
  const { config, conversations, users, members } = ctx;

  const conversationId = (id: string) => requireUuid(id, 'Conversation id');

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

    await assertUsersExist(memberIds);

    if (input.type === 'group') {
      const name = input.name?.trim();
      if (!name) {
        throw new ApiError('validation_error', 'A group needs a name');
      }

      const conversation = await conversations.createGroup({
        creatorId: request.userId,
        name,
        memberIds,
        avatarUrl: input.avatar_url,
        maxMembers: config.MAX_GROUP_MEMBERS,
      });
      await members.invalidate(conversation.id);
      await announce(conversation.id, [request.userId, ...memberIds]);
      const summary = await conversations.getSummary(conversation.id, request.userId);
      reply.status(201).send(summary);
      return;
    }

    if (memberIds.length !== 1) {
      throw new ApiError('validation_error', 'A direct conversation requires exactly one member');
    }
    const otherId = memberIds[0]!;
    const conversation = await conversations.findOrCreateDirect(request.userId, otherId);
    const summary = await conversations.getSummary(conversation.id, request.userId);
    reply.status(201).send(summary);
  });

  app.get('/api/v1/conversations/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    return conversations.getSummary(conversationId(id), request.userId);
  });

  app.patch('/api/v1/conversations/:id', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    const conversation = await conversations.requireGroup(conversationId(id));
    await conversations.requireAdmin(conversation.id, request.userId);
    const patch = parse(updateSchema, request.body);

    await conversations.updateGroup(conversation.id, {
      name: patch.name,
      avatarUrl: patch.avatar_url,
    });
    await announce(conversation.id, await members.ids(conversation.id));
    return conversations.getSummary(conversation.id, request.userId);
  });

  app.post('/api/v1/conversations/:id/members', async (request) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    const conversation = await conversations.requireGroup(conversationId(id));
    const input = parse(addMembersSchema, request.body);

    const userIds = [...new Set(input.user_ids.map((value) => requireUuid(value, 'user_ids')))];
    await assertUsersExist(userIds);

    await conversations.addMembers({
      conversationId: conversation.id,
      actorId: request.userId,
      userIds,
      maxMembers: config.MAX_GROUP_MEMBERS,
    });
    await members.invalidate(conversation.id);
    await announce(conversation.id, await members.ids(conversation.id));

    const summary = await conversations.getSummary(conversation.id, request.userId);
    return summary.members;
  });

  app.delete('/api/v1/conversations/:id/members/:userId', async (request, reply) => {
    requireAuth(request, config);
    const params = request.params as { id: string; userId: string };
    const conversation = await conversations.requireGroup(conversationId(params.id));
    const targetId = requireUuid(params.userId, 'User id');

    await conversations.removeMember({
      conversationId: conversation.id,
      actorId: request.userId,
      targetId,
    });
    await members.invalidate(conversation.id);
    // The removed member is told too, so their client can drop the group.
    await announce(conversation.id, [...(await members.ids(conversation.id)), targetId]);
    reply.status(204).send();
  });

  /** Pushes a lightweight refresh hint to online members of a conversation. */
  async function announce(conversationId: string, userIds: string[]): Promise<void> {
    await publishBroadcast(ctx.redis, [...new Set(userIds)], {
      type: 'conversation_updated',
      conversation_id: conversationId,
    });
  }

  async function assertUsersExist(ids: string[]): Promise<void> {
    const existing = await users.existingIds(ids);
    const missing = ids.find((id) => !existing.has(id));
    if (missing) {
      throw new ApiError('not_found', `User ${missing} not found`);
    }
  }
}
