import type { FastifyInstance } from 'fastify';
import { z } from 'zod';

import type { AppContext } from './context.js';
import { requireAuth } from './context.js';
import { ApiError } from '../lib/errors.js';
import { isUuid } from '../lib/ids.js';

/**
 * End-to-end encryption key registry.
 *
 * The client publishes public keys only; the server relays ciphertext and never
 * holds a private key. Bundle fetches consume a one-time prekey, which is why
 * they are not cacheable and are per-caller.
 */

const publishSchema = z.object({
  identity_key: z.string().min(1).max(512),
  signing_key: z.string().min(1).max(512),
  signed_prekey: z.object({
    key_id: z.coerce.number().int().min(1),
    public_key: z.string().min(1).max(512),
    signature: z.string().min(1).max(512),
  }),
  one_time_prekeys: z
    .array(
      z.object({
        key_id: z.coerce.number().int().min(1),
        public_key: z.string().min(1).max(512),
      }),
    )
    .max(200)
    .optional(),
  history_watermark: z.boolean().optional(),
});

const prekeysSchema = z.object({
  one_time_prekeys: z
    .array(
      z.object({
        key_id: z.coerce.number().int().min(1),
        public_key: z.string().min(1).max(512),
      }),
    )
    .min(1)
    .max(200),
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

export function registerKeyRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config, keys } = ctx;

  /** Publishes this device's identity key, signed prekey, and one-time prekeys. */
  app.post('/api/v1/keys', async (request, reply) => {
    requireAuth(request, config);
    const input = parse(publishSchema, request.body);

    const upsert = await keys.upsertIdentity({
      userId: request.userId,
      identityPublicKey: input.identity_key,
      signingPublicKey: input.signing_key,
      historyWatermark: input.history_watermark === true,
    });
    await keys.upsertSignedPrekey({
      userId: request.userId,
      keyId: input.signed_prekey.key_id,
      publicKey: input.signed_prekey.public_key,
      signature: input.signed_prekey.signature,
    });
    const added = await keys.addOneTimePrekeys(
      request.userId,
      (input.one_time_prekeys ?? []).map((prekey) => ({
        keyId: prekey.key_id,
        publicKey: prekey.public_key,
      })),
    );

    for (const item of upsert.clearedDirectConversations) {
      await ctx.broker.publishBroadcast(
        {
          user_ids: [request.userId],
          frame: {
            type: 'history_cleared',
            conversation_id: item.conversationId,
            cleared_seq: item.clearedSeq,
          },
        },
        `u:${request.userId}`,
      );
    }

    reply.status(201).send({
      // The client replenishes when this drops below its threshold.
      one_time_prekeys: await keys.countOneTimePrekeys(request.userId),
      added,
      key_epoch: upsert.identity.key_epoch,
      rotated_at: upsert.identity.rotated_at,
      rotated: upsert.rotated,
    });
  });

  /** Tops up one-time prekeys without re-publishing the identity/signed keys. */
  app.post('/api/v1/keys/prekeys', async (request) => {
    requireAuth(request, config);
    const input = parse(prekeysSchema, request.body);
    const added = await keys.addOneTimePrekeys(
      request.userId,
      input.one_time_prekeys.map((prekey) => ({
        keyId: prekey.key_id,
        publicKey: prekey.public_key,
      })),
    );
    return {
      added,
      one_time_prekeys: await keys.countOneTimePrekeys(request.userId),
    };
  });

  /** This device's own public key material, so it can verify what it uploaded. */
  app.get('/api/v1/keys/me', async (request) => {
    requireAuth(request, config);
    const identity = await keys.identity(request.userId);
    if (!identity) {
      throw new ApiError('keys_not_found', 'No keys published for this account');
    }
    return {
      user_id: identity.user_id,
      identity_key: identity.identity_public_key,
      signing_key: identity.signing_public_key,
      key_epoch: identity.key_epoch,
      rotated_at: identity.rotated_at,
      one_time_prekeys: await keys.countOneTimePrekeys(request.userId),
      updated_at: identity.updated_at,
    };
  });

  /**
   * Fetches the bundle needed to start an X3DH session with `id`.
   *
   * Consuming a one-time prekey makes the response un-cacheable and
   * per-caller, so this is `no-store` and never shared through a CDN.
   */
  app.get('/api/v1/keys/:id', async (request, reply) => {
    requireAuth(request, config);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) throw new ApiError('validation_error', 'User id must be a UUID');

    const bundle = await keys.takeBundle(id);
    reply.header('cache-control', 'no-store');
    return bundle;
  });
}
