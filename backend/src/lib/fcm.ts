import { readFile } from 'node:fs/promises';

import { initializeApp, cert, getApps, type App } from 'firebase-admin/app';
import { getMessaging, type Messaging } from 'firebase-admin/messaging';

import type { Config } from '../config.js';
import type { Logger } from './logger.js';

export type PushPayload = {
  title: string;
  body: string;
  conversationId: string;
  messageId: string;
  senderName: string;
  conversationName: string;
  type: string;
};

/**
 * FCM push for recipients with no live gateway connection.
 *
 * The service is optional: without `FCM_CREDENTIALS_FILE` (or an explicit JSON
 * blob) it disables itself and logs the reason once, so local development and
 * CI do not need a Firebase project. Message content is never logged.
 */
export class NotificationService {
  private app: App | null = null;
  private messaging: Messaging | null = null;

  constructor(
    private readonly config: Config,
    private readonly logger: Logger,
  ) {}

  async initialize(): Promise<void> {
    const credentials = await this.loadCredentials();
    if (!credentials) {
      this.logger.info('FCM disabled: no credentials configured');
      return;
    }

    try {
      this.app =
        getApps().find((app) => app.name === 'cp-chat') ??
        initializeApp({ credential: cert(credentials) }, 'cp-chat');
      this.messaging = getMessaging(this.app);
      this.logger.info('FCM initialized');
    } catch (error) {
      this.logger.warn({ err: error }, 'FCM initialization failed; continuing without push');
      this.app = null;
      this.messaging = null;
    }
  }

  get enabled(): boolean {
    return this.messaging !== null;
  }

  /**
   * Sends one data+notification message per Firebase Installation ID (FID).
   * Stale installation ids are returned so the caller can prune them.
   *
   * The Flutter plugin's `register()`/`onRegistered` stream yields the FID, and
   * firebase-admin 14 addresses installs by FID, so `getToken()`'s registration
   * token is deliberately not used.
   */
  async notify(fids: string[], payload: PushPayload): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    try {
      const response = await this.messaging.sendEachForMulticast({
        fids,
        notification: { title: payload.title, body: payload.body },
        data: {
          conversation_id: payload.conversationId,
          message_id: payload.messageId,
          sender_name: payload.senderName,
          conversation_name: payload.conversationName,
          type: payload.type,
        },
        android: {
          priority: 'high',
          notification: { channelId: 'cpchat_messages', sound: 'default' },
        },
      });

      const stale: string[] = [];
      response.responses.forEach((result, index) => {
        const code = result.error?.code;
        if (
          code === 'messaging/installation-id-not-registered' ||
          code === 'messaging/registration-token-not-registered' ||
          code === 'messaging/invalid-argument'
        ) {
          const fid = fids[index];
          if (fid) stale.push(fid);
        }
      });
      return stale;
    } catch (error) {
      this.logger.warn({ err: error }, 'FCM send failed');
      return [];
    }
  }

  private async loadCredentials(): Promise<Record<string, unknown> | null> {
    const file = this.config.FCM_CREDENTIALS_FILE;
    if (!file) return null;
    try {
      return JSON.parse(await readFile(file, 'utf8')) as Record<string, unknown>;
    } catch (error) {
      this.logger.warn({ err: error, file }, 'Could not read FCM credentials file');
      return null;
    }
  }
}
