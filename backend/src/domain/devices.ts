import type { Db } from '../lib/db.js';

export type DeviceTokenRow = {
  device_id: string;
  fcm_token: string;
  push_version: number;
};

export class DeviceRepository {
  constructor(private readonly db: Db) {}

  /**
   * The FCM token identifies the physical install, so re-registering from a new
   * account or a rotated device id replaces the previous binding instead of
   * accumulating rows that would duplicate pushes.
   */
  async register(
    userId: string,
    deviceId: string,
    fcmToken: string,
    pushVersion = 1,
  ): Promise<void> {
    await this.db.query(
      `DELETE FROM device_tokens
        WHERE fcm_token = $3 AND NOT (user_id = $1 AND device_id = $2)`,
      [userId, deviceId, fcmToken],
    );
    await this.db.query(
      `INSERT INTO device_tokens (user_id, device_id, fcm_token, push_version, updated_at)
       VALUES ($1, $2, $3, $4, NOW())
       ON CONFLICT (user_id, device_id)
       DO UPDATE SET fcm_token = EXCLUDED.fcm_token,
                     push_version = EXCLUDED.push_version,
                     updated_at = NOW()`,
      [userId, deviceId, fcmToken, pushVersion],
    );
  }

  async unregister(userId: string, deviceId: string): Promise<void> {
    await this.db.query(`DELETE FROM device_tokens WHERE user_id = $1 AND device_id = $2`, [
      userId,
      deviceId,
    ]);
  }

  async unregisterMatching(
    userId: string,
    options: { deviceIds?: string[]; fcmToken?: string },
  ): Promise<void> {
    const deviceIds = [...new Set((options.deviceIds ?? []).filter((id) => id.length > 0))];
    const fcmToken = options.fcmToken?.trim() || undefined;
    if (deviceIds.length === 0 && !fcmToken) return;

    if (deviceIds.length > 0 && fcmToken) {
      await this.db.query(
        `DELETE FROM device_tokens
          WHERE user_id = $1
            AND (device_id = ANY($2::text[]) OR fcm_token = $3)`,
        [userId, deviceIds, fcmToken],
      );
      return;
    }
    if (deviceIds.length > 0) {
      await this.db.query(
        `DELETE FROM device_tokens WHERE user_id = $1 AND device_id = ANY($2::text[])`,
        [userId, deviceIds],
      );
      return;
    }
    await this.db.query(
      `DELETE FROM device_tokens WHERE user_id = $1 AND fcm_token = $2`,
      [userId, fcmToken],
    );
  }

  /**
   * Drops installations FCM reported as unregistered so a dead token is never
   * retried. Tokens are global identifiers, so this is not scoped to one user.
   */
  async removeStale(fcmTokens: string[]): Promise<void> {
    if (fcmTokens.length === 0) return;
    await this.db.query(`DELETE FROM device_tokens WHERE fcm_token = ANY($1::text[])`, [fcmTokens]);
  }

  async tokensForUser(userId: string): Promise<DeviceTokenRow[]> {
    const { rows } = await this.db.query<DeviceTokenRow>(
      `SELECT device_id, fcm_token, push_version FROM device_tokens WHERE user_id = $1`,
      [userId],
    );
    return rows;
  }
}
