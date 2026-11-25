import type { Db } from '../lib/db.js';

export class DeviceRepository {
  constructor(private readonly db: Db) {}

  /**
   * The FCM token identifies the physical install, so re-registering from a new
   * account or a rotated device id replaces the previous binding instead of
   * accumulating rows that would duplicate pushes.
   */
  async register(userId: string, deviceId: string, fcmToken: string): Promise<void> {
    await this.db.query(
      `DELETE FROM device_tokens
        WHERE fcm_token = $3 AND NOT (user_id = $1 AND device_id = $2)`,
      [userId, deviceId, fcmToken],
    );
    await this.db.query(
      `INSERT INTO device_tokens (user_id, device_id, fcm_token, updated_at)
       VALUES ($1, $2, $3, NOW())
       ON CONFLICT (user_id, device_id)
       DO UPDATE SET fcm_token = EXCLUDED.fcm_token, updated_at = NOW()`,
      [userId, deviceId, fcmToken],
    );
  }

  async unregister(userId: string, deviceId: string): Promise<void> {
    await this.db.query(`DELETE FROM device_tokens WHERE user_id = $1 AND device_id = $2`, [
      userId,
      deviceId,
    ]);
  }

  /**
   * Drops installations FCM reported as unregistered so a dead token is never
   * retried. Tokens are global identifiers, so this is not scoped to one user.
   */
  async removeStale(fcmTokens: string[]): Promise<void> {
    if (fcmTokens.length === 0) return;
    await this.db.query(`DELETE FROM device_tokens WHERE fcm_token = ANY($1::text[])`, [fcmTokens]);
  }

  async tokensForUser(userId: string): Promise<{ device_id: string; fcm_token: string }[]> {
    const { rows } = await this.db.query<{ device_id: string; fcm_token: string }>(
      `SELECT device_id, fcm_token FROM device_tokens WHERE user_id = $1`,
      [userId],
    );
    return rows;
  }
}
