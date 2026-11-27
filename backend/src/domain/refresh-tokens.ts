import { ApiError } from '../lib/errors.js';
import { withTransaction, type Db } from '../lib/db.js';
import { generateRefreshToken, hashRefreshToken } from '../lib/tokens.js';

export type RefreshTokenRow = {
  id: string;
  user_id: string;
  expires_at: Date;
  revoked_at: Date | null;
  replaced_by: string | null;
};

/**
 * Refresh tokens are rotated on every use. Presenting an already-rotated token
 * means it leaked, so the whole family is revoked immediately.
 */
export class RefreshTokenRepository {
  constructor(
    private readonly db: Db,
    private readonly ttlSeconds: number,
  ) {}

  async issue(userId: string, deviceId: string | null): Promise<{ token: string; id: string }> {
    const { token, hash } = generateRefreshToken();
    const expiresAt = new Date(Date.now() + this.ttlSeconds * 1000);
    const { rows } = await this.db.query<{ id: string }>(
      `INSERT INTO refresh_tokens (user_id, token_hash, device_id, expires_at)
       VALUES ($1, $2, $3, $4)
       RETURNING id`,
      [userId, hash, deviceId, expiresAt],
    );
    return { token, id: rows[0]!.id };
  }

  async rotate(
    presentedToken: string,
    deviceId: string | null,
  ): Promise<{ userId: string; token: string; id: string }> {
    const hash = hashRefreshToken(presentedToken);
    const outcome = await withTransaction(this.db, async (client) => {
      const { rows } = await client.query<RefreshTokenRow>(
        `SELECT id, user_id, expires_at, revoked_at, replaced_by
           FROM refresh_tokens
          WHERE token_hash = $1
            FOR UPDATE`,
        [hash],
      );
      const row = rows[0];
      if (!row) {
        return { kind: 'not_found' as const };
      }

      if (row.revoked_at) {
        await client.query(
          `UPDATE refresh_tokens SET revoked_at = NOW()
            WHERE user_id = $1 AND revoked_at IS NULL`,
          [row.user_id],
        );
        return { kind: 'revoked' as const };
      }

      if (row.expires_at.getTime() <= Date.now()) {
        return { kind: 'expired' as const };
      }

      const { token, hash: nextHash } = generateRefreshToken();
      const expiresAt = new Date(Date.now() + this.ttlSeconds * 1000);
      const inserted = await client.query<{ id: string }>(
        `INSERT INTO refresh_tokens (user_id, token_hash, device_id, expires_at)
         VALUES ($1, $2, $3, $4)
         RETURNING id`,
        [row.user_id, nextHash, deviceId, expiresAt],
      );
      const nextId = inserted.rows[0]!.id;

      await client.query(
        `UPDATE refresh_tokens
            SET revoked_at = NOW(), replaced_by = $2
          WHERE id = $1 AND revoked_at IS NULL`,
        [row.id, nextId],
      );

      return { kind: 'ok' as const, userId: row.user_id, token, id: nextId };
    });

    if (outcome.kind === 'not_found') {
      throw new ApiError('invalid_token', 'Refresh token is not recognised');
    }
    if (outcome.kind === 'revoked') {
      throw new ApiError('invalid_token', 'Refresh token has been revoked');
    }
    if (outcome.kind === 'expired') {
      throw new ApiError('invalid_token', 'Refresh token has expired');
    }

    return { userId: outcome.userId, token: outcome.token, id: outcome.id };
  }

  async revoke(presentedToken: string): Promise<{ userId: string; deviceId: string | null } | null> {
    const { rows } = await this.db.query<{ user_id: string; device_id: string | null }>(
      `UPDATE refresh_tokens SET revoked_at = NOW()
        WHERE token_hash = $1 AND revoked_at IS NULL
        RETURNING user_id, device_id`,
      [hashRefreshToken(presentedToken)],
    );
    const row = rows[0];
    return row ? { userId: row.user_id, deviceId: row.device_id } : null;
  }

  async revokeFamily(userId: string): Promise<void> {
    await this.db.query(
      `UPDATE refresh_tokens SET revoked_at = NOW()
        WHERE user_id = $1 AND revoked_at IS NULL`,
      [userId],
    );
  }
}
