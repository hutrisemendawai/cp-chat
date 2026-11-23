import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
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

/** Strips any `; charset=...` parameter so only the media type is compared. */
function baseContentType(value: string | undefined): string {
  return (value ?? '').split(';')[0]!.trim().toLowerCase();
}

const TRUE_VALUES = new Set(['1', 'true', 'yes']);
const FALSE_VALUES = new Set(['0', 'false', 'no']);

/** Resolves whether this download should be streamed rather than redirected. */
function shouldProxyDownload(request: FastifyRequest, config: AppContext['config']): boolean {
  const query = request.query as { proxy?: unknown } | undefined;
  if (typeof query?.proxy === 'string') {
    const value = query.proxy.trim().toLowerCase();
    if (FALSE_VALUES.has(value)) return false;
    if (TRUE_VALUES.has(value)) return true;
  }
  return config.MEDIA_PROXY_DOWNLOAD;
}

export function registerMediaRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, media, storage, users } = ctx;

  const allowed = new Set(
    config.MEDIA_ALLOWED_TYPES.split(',').map((type) => type.trim().toLowerCase()).filter(Boolean),
  );

  const rejectUnlessAllowed = (contentType: string) => {
    if (!allowed.has(contentType)) {
      throw new ApiError(
        'unsupported_media_type',
        `Unsupported content type: ${contentType}`,
      );
    }
  };

  const rejectUnlessWithinLimit = (sizeBytes: number) => {
    if (sizeBytes > config.MEDIA_MAX_BYTES) {
      throw new ApiError(
        'media_too_large',
        `Files are limited to ${Math.floor(config.MEDIA_MAX_BYTES / (1024 * 1024))} MB`,
      );
    }
  };

  app.post('/api/v1/media/presign', async (request, reply) => {
    requireAuth(request, config);
    const input = parse(presignSchema, request.body);
    const contentType = input.content_type.toLowerCase();

    rejectUnlessAllowed(contentType);
    rejectUnlessWithinLimit(input.size_bytes);

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
   * API-proxied upload: the phone posts the bytes here and the API writes them
   * to object storage through the internal S3 client. This is what lets a
   * physical device upload media when only `API_BASE_URL` is reachable — no
   * direct access to port 9000 is required.
   *
   * Accepts a raw binary body with a `Content-Type` and `x-filename` header.
   * Registered inside a scoped plugin so the wildcard buffer content-type
   * parser and the larger body limit apply to this route only.
   */
  app.register(async (scope) => {
    scope.addContentTypeParser(
      '*',
      { parseAs: 'buffer', bodyLimit: config.MEDIA_MAX_BYTES },
      (_request, body, done) => {
        done(null, body);
      },
    );

    scope.post(
      '/api/v1/media/upload',
      { bodyLimit: config.MEDIA_MAX_BYTES },
      async (request, reply) => {
        requireAuth(request, config);

        const contentType = baseContentType(request.headers['content-type']);
        const filenameHeader = request.headers['x-filename'];
        const filename =
          typeof filenameHeader === 'string' && filenameHeader.trim()
            ? filenameHeader.trim().slice(0, 255)
            : `upload${contentType.startsWith('image/') ? '.jpg' : ''}`;

        const body = request.body;
        if (!Buffer.isBuffer(body) || body.length === 0) {
          throw new ApiError('validation_error', 'Upload body is empty');
        }

        rejectUnlessAllowed(contentType);
        rejectUnlessWithinLimit(body.length);

        const objectKey = storage.buildKey(request.userId, filename, contentType);
        await storage.putObject(objectKey, body, contentType);

        const record = await media.create({
          ownerId: request.userId,
          objectKey,
          contentType,
          sizeBytes: body.length,
          originalName: filename,
        });

        reply.status(201).send({
          media_id: record.id,
          object_key: objectKey,
          file_url: storage.objectUrl(objectKey),
          content_type: record.content_type,
          size_bytes: record.size_bytes,
        });
      },
    );
  });

  /**
   * Serves media by object key. The bucket is private, so the client cannot read
   * the object directly; this endpoint authorizes the caller (any authenticated
   * user who can see the key).
   *
   * By default the bytes are streamed through the API via the internal S3
   * client, so a device only needs to reach `API_BASE_URL`. `?proxy=0` (or
   * `MEDIA_PROXY_DOWNLOAD=false`) restores the redirect-to-presigned-GET
   * behaviour for callers that can reach the storage host directly.
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

    if (!shouldProxyDownload(request, config)) {
      const url = await storage.presignDownload(key);
      reply.header('cache-control', 'private, max-age=300');
      reply.redirect(url, 302);
      return;
    }

    await streamObject(storage, key, record.content_type, record.size_bytes, reply);
  });
}

/**
 * Streams an object from storage to the reply. A presign can create the
 * `media_objects` row before the PUT lands, so a missing object is reported as
 * `404` rather than an internal error.
 */
async function streamObject(
  storage: AppContext['storage'],
  key: string,
  contentType: string,
  sizeBytes: number,
  reply: FastifyReply,
): Promise<void> {
  let object;
  try {
    object = await storage.getObject(key);
  } catch {
    throw new ApiError('not_found', 'Media object is missing from storage');
  }

  reply.header('content-type', object.contentType ?? contentType);
  reply.header('content-length', object.contentLength ?? sizeBytes);
  reply.header('cache-control', 'private, max-age=300');
  return reply.send(object.body);
}
