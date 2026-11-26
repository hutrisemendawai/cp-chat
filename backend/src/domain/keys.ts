import { ApiError } from '../lib/errors.js';
import { withTransaction, type Db } from '../lib/db.js';

/** Anything that can run a query: the pool, or a transaction's client. */
type Queryable = Pick<Db, 'query'>;

/**
 * Public key registry for end-to-end encrypted direct chats.
 *
 * This is a blind store: every value is a base64 public key or signature, and
 * the server has no way to derive a message key from them. Handing out a
 * one-time prekey *deletes* it in the same transaction, so two senders starting
 * a session to the same recipient can never be given the same key — that would
 * let one of them impersonate the other.
 */

export type IdentityKeyRow = {
  user_id: string;
  identity_public_key: string;
  signing_public_key: string;
  key_epoch: number;
  rotated_at: Date;
  created_at: Date;
  updated_at: Date;
};

export type UpsertIdentityResult = {
  identity: IdentityKeyRow;
  rotated: boolean;
  clearedDirectConversations: { conversationId: string; clearedSeq: number }[];
};

export type SignedPrekeyRow = {
  user_id: string;
  key_id: number;
  public_key: string;
  signature: string;
  created_at: Date;
};

export type OneTimePrekeyRow = {
  user_id: string;
  key_id: number;
  public_key: string;
};

/** The bundle a sender needs to run X3DH against a recipient. */
export type PrekeyBundle = {
  user_id: string;
  identity_key: string;
  signing_key: string;
  signed_prekey: { key_id: number; public_key: string; signature: string };
  one_time_prekey: { key_id: number; public_key: string } | null;
  remaining_one_time_prekeys: number;
};

const MAX_PREKEYS_PER_UPLOAD = 200;

export class KeyRepository {
  constructor(private readonly db: Db) {}

  async identity(userId: string): Promise<IdentityKeyRow | null> {
    return this.identityWith(this.db, userId);
  }

  /** [identity] against an explicit connection, so a transaction sees its own writes. */
  private async identityWith(
    client: Queryable,
    userId: string,
    forUpdate = false,
  ): Promise<IdentityKeyRow | null> {
    const lock = forUpdate ? ' FOR UPDATE' : '';
    const { rows } = await client.query<IdentityKeyRow>(
      `SELECT user_id, identity_public_key, signing_public_key,
              key_epoch, rotated_at, created_at, updated_at
         FROM user_identity_keys WHERE user_id = $1${lock}`,
      [userId],
    );
    return rows[0] ?? null;
  }

  /**
   * Publishes or rotates the identity keys. Changing the identity key is how a
   * device re-installs or clears data, so it is allowed — peers see the new key
   * on their next bundle fetch and must re-verify it out of band.
   *
   * A rotation discards every one-time prekey already on file and increments
   * `key_epoch` / updates `rotated_at`. When the caller advertises
   * `historyWatermark: true`, the user's direct-chat history watermarks are
   * advanced to `last_seq` inside the same transaction so cryptographically
   * unreadable pre-rotation ciphertexts are never re-served as stubs. Groups
   * are plaintext and untouched.
   */
  async upsertIdentity(input: {
    userId: string;
    identityPublicKey: string;
    signingPublicKey: string;
    historyWatermark?: boolean;
  }): Promise<UpsertIdentityResult> {
    return withTransaction(this.db, async (client) => {
      const previous = await this.identityWith(client, input.userId, true);
      const rotated =
        previous !== null && previous.identity_public_key !== input.identityPublicKey;

      const { rows } = await client.query<IdentityKeyRow>(
        `INSERT INTO user_identity_keys (user_id, identity_public_key, signing_public_key, key_epoch, rotated_at)
         VALUES ($1, $2, $3, 1, NOW())
         ON CONFLICT (user_id) DO UPDATE
           SET identity_public_key = EXCLUDED.identity_public_key,
               signing_public_key = EXCLUDED.signing_public_key,
               key_epoch = CASE WHEN $4 THEN user_identity_keys.key_epoch + 1 ELSE user_identity_keys.key_epoch END,
               rotated_at = CASE WHEN $4 THEN NOW() ELSE user_identity_keys.rotated_at END,
               updated_at = NOW()
         RETURNING user_id, identity_public_key, signing_public_key,
                   key_epoch, rotated_at, created_at, updated_at`,
        [input.userId, input.identityPublicKey, input.signingPublicKey, rotated],
      );

      let clearedDirectConversations: { conversationId: string; clearedSeq: number }[] = [];

      // A routine republish (same device, same identity) keeps its supply and
      // epoch; only an actual rotation orphans the stored prekeys and advances
      // direct-chat watermarks (when gated by the capability flag).
      if (rotated) {
        await client.query(`DELETE FROM user_one_time_prekeys WHERE user_id = $1`, [
          input.userId,
        ]);

        if (input.historyWatermark === true) {
          const cleared = await client.query<{ conversation_id: string; cleared_seq: string }>(
            `UPDATE conversation_members cm
                SET cleared_seq = GREATEST(cm.cleared_seq, c.last_seq),
                    last_read_seq = GREATEST(cm.last_read_seq, c.last_seq)
               FROM conversations c
              WHERE cm.conversation_id = c.id
                AND cm.user_id = $1
                AND c.type = 'direct'
             RETURNING cm.conversation_id, cm.cleared_seq`,
            [input.userId],
          );
          clearedDirectConversations = cleared.rows.map((row) => ({
            conversationId: row.conversation_id,
            clearedSeq: Number(row.cleared_seq),
          }));
        }
      }

      return {
        identity: rows[0]!,
        rotated,
        clearedDirectConversations,
      };
    });
  }

  async upsertSignedPrekey(input: {
    userId: string;
    keyId: number;
    publicKey: string;
    signature: string;
  }): Promise<SignedPrekeyRow> {
    const { rows } = await this.db.query<SignedPrekeyRow>(
      `INSERT INTO user_signed_prekeys (user_id, key_id, public_key, signature)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (user_id) DO UPDATE
         SET key_id = EXCLUDED.key_id,
             public_key = EXCLUDED.public_key,
             signature = EXCLUDED.signature,
             created_at = NOW()
       RETURNING user_id, key_id, public_key, signature, created_at`,
      [input.userId, input.keyId, input.publicKey, input.signature],
    );
    return rows[0]!;
  }

  /**
   * Adds one-time prekeys. Re-uploading the same key id is a no-op so a client
   * that lost the response can retry safely.
   */
  async addOneTimePrekeys(
    userId: string,
    prekeys: { keyId: number; publicKey: string }[],
  ): Promise<number> {
    if (prekeys.length === 0) return 0;
    if (prekeys.length > MAX_PREKEYS_PER_UPLOAD) {
      throw new ApiError(
        'validation_error',
        `Upload at most ${MAX_PREKEYS_PER_UPLOAD} one-time prekeys at a time`,
      );
    }

    const { rowCount } = await this.db.query(
      `INSERT INTO user_one_time_prekeys (user_id, key_id, public_key)
       SELECT $1, key_id, public_key
         FROM unnest($2::int[], $3::text[]) AS t(key_id, public_key)
       ON CONFLICT (user_id, key_id) DO NOTHING`,
      [userId, prekeys.map((prekey) => prekey.keyId), prekeys.map((prekey) => prekey.publicKey)],
    );
    return rowCount ?? 0;
  }

  async countOneTimePrekeys(userId: string): Promise<number> {
    const { rows } = await this.db.query<{ count: string }>(
      `SELECT count(*)::text AS count FROM user_one_time_prekeys WHERE user_id = $1`,
      [userId],
    );
    return Number(rows[0]?.count ?? 0);
  }

  /**
   * Returns the bundle for `userId` and, when available, consumes one
   * one-time prekey.
   *
   * `DELETE ... RETURNING` makes the consume atomic: two concurrent fetches
   * cannot both receive the same key row, so there is no window in which two
   * initiators build a session from one prekey.
   */
  async takeBundle(userId: string): Promise<PrekeyBundle> {
    const identity = await this.identity(userId);
    if (!identity) {
      throw new ApiError('keys_not_found', 'This user has not published encryption keys');
    }

    const { rows: signedRows } = await this.db.query<SignedPrekeyRow>(
      `SELECT user_id, key_id, public_key, signature, created_at
         FROM user_signed_prekeys WHERE user_id = $1`,
      [userId],
    );
    const signed = signedRows[0];
    if (!signed) {
      throw new ApiError('keys_not_found', 'This user has not published a signed prekey');
    }

    const { rows: oneTimeRows } = await this.db.query<OneTimePrekeyRow>(
      `DELETE FROM user_one_time_prekeys
        WHERE (user_id, key_id) IN (
          SELECT user_id, key_id FROM user_one_time_prekeys
           WHERE user_id = $1 ORDER BY key_id ASC LIMIT 1
        )
        RETURNING user_id, key_id, public_key`,
      [userId],
    );
    const oneTime = oneTimeRows[0] ?? null;

    return {
      user_id: userId,
      identity_key: identity.identity_public_key,
      signing_key: identity.signing_public_key,
      signed_prekey: {
        key_id: signed.key_id,
        public_key: signed.public_key,
        signature: signed.signature,
      },
      one_time_prekey: oneTime ? { key_id: oneTime.key_id, public_key: oneTime.public_key } : null,
      remaining_one_time_prekeys: await this.countOneTimePrekeys(userId),
    };
  }

  /** True when a user has published the minimum keys to be messaged. */
  async ready(userId: string): Promise<boolean> {
    const { rows } = await this.db.query(
      `SELECT 1
         FROM user_identity_keys i
         JOIN user_signed_prekeys s ON s.user_id = i.user_id
        WHERE i.user_id = $1`,
      [userId],
    );
    return rows.length > 0;
  }
}
