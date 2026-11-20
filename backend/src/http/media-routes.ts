import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { verifyAccessToken } from '../lib/tokens.js';

const presignSchema = z.object({
  filename: z.string().trim().min(1).max(255),
  content_type: z.string().trim().min(3).max(255),
  size_bytes: z.coerce.number().int().positive(),
});

/**
 * Media is loaded by image widgets and external download handlers that cannot
 * always set an Authorization header. Accept the bearer header when present,
 * and fall back to a `?token=` query parameter (the same pattern the WebSocket
 * upgrade uses).
 */
function authenticateMedia(request: FastifyRequest, config: AppContext['config']): void {
  const header = request.headers.authorization;
  const query = request.query as { token?: unknown } | undefined;
  const queryToken = typeof query?.token === 'string' ? query.token : null;

  const token = header?.startsWith('Bearer ')
    ? header.slice('Bearer '.length).trim()
    : queryToken;
  if (!token) {
    throw new ApiError('unauthorized', 'Missing access token');
  }

  const payload = verifyAccessToken(token, config);
  request.userId = payload.sub;
  request.deviceId = payload.device_id;
}

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

export function registerMediaRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, media, storage, users } = ctx;

  const allowed = new Set(
    config.MEDIA_ALLOWED_TYPES.split(',').map((type) => type.trim().toLowerCase()).filter(Boolean),
  );

  app.post('/api/v1/media/presign', async (request, reply) => {
    requireAuth(request, config);
    const input = parse(presignSchema, request.body);
    const contentType = input.content_type.toLowerCase();

    if (!allowed.has(contentType)) {
      throw new ApiError(
        'unsupported_media_type',
        `Unsupported content type: ${input.content_type}`,
      );
    }
    if (input.size_bytes > config.MEDIA_MAX_BYTES) {
      throw new ApiError(
        'media_too_large',
        `Files are limited to ${Math.floor(config.MEDIA_MAX_BYTES / (1024 * 1024))} MB`,
      );
    }

    const objectKey = storage.buildKey(request.userId, input.filename, contentType);
    const presigned = await storage.presignUpload({
      key: objectKey,
      contentType,
      sizeBytes: input.size_bytes,
    });
    const record = await media.create({
      ownerId: request.userId,
      objectKey,
      contentType,
      sizeBytes: input.size_bytes,
      originalName: input.filename,
    });

    reply.status(201).send({
      media_id: record.id,
      object_key: objectKey,
      upload_url: presigned.uploadUrl,
      file_url: presigned.fileUrl,
      content_type: record.content_type,
      size_bytes: record.size_bytes,
      expires_at: presigned.expiresAt.toISOString(),
    });
  });

  /**
   * Serves media by object key. The bucket is private, so the client cannot read
   * the object directly; this endpoint authorizes the caller (any authenticated
   * user who can see the key) and redirects to a short-lived presigned GET.
   */
  app.get('/api/v1/media/*', async (request, reply) => {
    authenticateMedia(request, config);
    const { '*': key } = request.params as { '*': string };
    if (!key) {
      throw new ApiError('validation_error', 'Media key is required');
    }

    const record = await media.findByKey(key);
    if (!record) {
      throw new ApiError('not_found', 'Media not found');
    }

    // Readers are the owner or anyone who shares a conversation with them. A
    // full ACL is out of scope; the object key is only shared inside message
    // bodies visible to conversation members.
    if (record.owner_id !== request.userId) {
      const shares = await users.sharesConversationWith(record.owner_id, request.userId);
      if (!shares) {
        throw new ApiError('forbidden', 'You cannot access this media');
      }
    }

    const url = await storage.presignDownload(key);
    reply.header('cache-control', 'private, max-age=300');
    reply.redirect(url, 302);
  });
}
