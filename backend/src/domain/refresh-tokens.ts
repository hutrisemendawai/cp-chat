import { ApiError } from '../lib/errors.js';
import type { Db } from '../lib/db.js';
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
    const { rows } = await this.db.query<RefreshTokenRow>(
      `SELECT id, user_id, expires_at, revoked_at, replaced_by
         FROM refresh_tokens
        WHERE token_hash = $1`,
      [hash],
    );
    const row = rows[0];
    if (!row) {
      throw new ApiError('invalid_token', 'Refresh token is not recognised');
    }

    if (row.revoked_at) {
      await this.revokeFamily(row.user_id);
      throw new ApiError('invalid_token', 'Refresh token has been revoked');
    }

    if (row.expires_at.getTime() <= Date.now()) {
      throw new ApiError('invalid_token', 'Refresh token has expired');
    }

    const next = await this.issue(row.user_id, deviceId);
    await this.db.query(
      `UPDATE refresh_tokens
          SET revoked_at = NOW(), replaced_by = $2
        WHERE id = $1 AND revoked_at IS NULL`,
      [row.id, next.id],
    );

    return { userId: row.user_id, token: next.token, id: next.id };
  }

  async revoke(presentedToken: string): Promise<void> {
    await this.db.query(
      `UPDATE refresh_tokens SET revoked_at = NOW()
        WHERE token_hash = $1 AND revoked_at IS NULL`,
      [hashRefreshToken(presentedToken)],
    );
  }

  async revokeFamily(userId: string): Promise<void> {
    await this.db.query(
      `UPDATE refresh_tokens SET revoked_at = NOW()
        WHERE user_id = $1 AND revoked_at IS NULL`,
      [userId],
    );
  }
}
