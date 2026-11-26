import { readFile } from 'node:fs/promises';

import { initializeApp, cert, getApps, type App, type ServiceAccount } from 'firebase-admin/app';
import { getMessaging, type Messaging } from 'firebase-admin/messaging';

import type { Config } from '../config.js';
import type { Logger } from './logger.js';

export type PushPayload = {
  title: string;
  body: string;
  conversationId: string;
  messageId: string;
  senderId: string;
  senderName: string;
  recipientUserId: string;
  conversationName: string;
  type: string;
  conversationType?: 'direct' | 'group';
  clientMsgId?: string;
  seq?: number;
  createdAt?: string;
  content?: string;
};

/**
 * Maximum UTF-8 JSON size for the FCM `data` map. FCM enforces a hard 4,096 B
 * limit; budgeting at 3,500 B leaves comfortable headroom for wire framing and
 * guarantees `invalid-argument` is never triggered (which would otherwise be
 * treated as a stale installation ID).
 */
export const MAX_FCM_DATA_BYTES = 3500;

/**
 * Builds the `push_schema: "2"` string-only FCM `data` map for clients capable
 * of decrypting E2EE payloads in their background isolate.
 *
 * When including `payload.content` would exceed {@link MAX_FCM_DATA_BYTES},
 * `content` is omitted and `content_omitted: "true"` is set so the client
 * fetches the ciphertext via `/conversations/:id/sync` instead.
 */
export function buildDataOnlyMap(payload: PushPayload): Record<string, string> {
  const base: Record<string, string> = {
    push_schema: '2',
    type: payload.type,
    msg_type: payload.type,
    conversation_id: payload.conversationId,
    conversation_type: payload.conversationType ?? 'direct',
    conversation_name: payload.conversationName,
    message_id: payload.messageId,
    client_msg_id: payload.clientMsgId ?? '',
    seq: payload.seq !== undefined ? String(payload.seq) : '',
    sender_id: payload.senderId,
    sender_name: payload.senderName,
    recipient_user_id: payload.recipientUserId,
    created_at: payload.createdAt ?? '',
  };

  if (payload.content !== undefined) {
    const withContent: Record<string, string> = { ...base, content: payload.content };
    if (Buffer.byteLength(JSON.stringify(withContent), 'utf8') <= MAX_FCM_DATA_BYTES) {
      return withContent;
    }
  }

  return { ...base, content_omitted: 'true' };
}

/**
 * Error codes that mean the target install no longer exists. Returning them
 * lets the caller prune the row instead of retrying a dead installation forever.
 */
const STALE_TOKEN_CODES = new Set([
  'messaging/installation-id-not-registered',
  'messaging/registration-token-not-registered',
  'messaging/unregistered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

/**
 * FCM push for recipients with no live gateway connection.
 *
 * The service is optional: without credentials it disables itself and logs the
 * reason, so local development and CI do not need a Firebase project. Message
 * content is never logged. Credentials come either from `FCM_CREDENTIALS_FILE`
 * (a service-account JSON file) or from inline `FIREBASE_PROJECT_ID` /
 * `FIREBASE_CLIENT_EMAIL` / `FIREBASE_PRIVATE_KEY`, which is what container
 * deploys use because it needs no mounted file.
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
      this.logger.warn(
        'FCM disabled: set FCM_CREDENTIALS_FILE or ' +
          'FIREBASE_PROJECT_ID + FIREBASE_CLIENT_EMAIL + FIREBASE_PRIVATE_KEY',
      );
      return;
    }

    try {
      this.app =
        getApps().find((app) => app.name === 'cp-chat') ??
        initializeApp({ credential: cert(credentials) }, 'cp-chat');
      this.messaging = getMessaging(this.app);
      this.logger.info({ project_id: credentials.projectId }, 'FCM initialized');
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
   * Sends one legacy data+notification message per Firebase Installation ID
   * (FID) for older installs (`push_version == 1`). Stale installation ids are
   * returned so the caller can prune them.
   *
   * The Flutter plugin's `register()`/`onRegistered` stream yields the FID, and
   * firebase-admin 14 addresses installs by FID, so `getToken()`'s registration
   * token is deliberately not used.
   */
  async notify(fids: string[], payload: PushPayload): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    return this.sendMulticast(fids, 'legacy', {
      fids,
      // Legacy fallback for push_version == 1 clients: the OS renders the
      // notification block directly when the app is terminated.
      notification: { title: payload.title, body: payload.body },
      data: {
        type: payload.type,
        conversation_id: payload.conversationId,
        message_id: payload.messageId,
        sender_id: payload.senderId,
        sender_name: payload.senderName,
        recipient_user_id: payload.recipientUserId,
        conversation_name: payload.conversationName,
      },
      android: {
        // `high` is required for Doze-delivered alerts: a normal-priority
        // push can be deferred or dropped when the app is terminated.
        priority: 'high',
        notification: { channelId: 'cpchat_messages', sound: 'default' },
      },
    });
  }

  /**
   * Sends a high-priority data-only FCM message (`push_schema: "2"`) per FID
   * for upgraded clients (`push_version >= 2`). Omitting both top-level
   * `notification` and `android.notification` ensures Android wakes the
   * background isolate even when the app is terminated so the client can
   * decrypt the E2EE envelope locally and render the real message preview.
   */
  async notifyDataOnly(fids: string[], payload: PushPayload): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    return this.sendMulticast(fids, 'data_only', {
      fids,
      data: buildDataOnlyMap(payload),
      android: {
        priority: 'high',
      },
    });
  }

  private async sendMulticast(
    fids: string[],
    mode: 'legacy' | 'data_only',
    message: Parameters<Messaging['sendEachForMulticast']>[0],
  ): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    try {
      const response = await this.messaging.sendEachForMulticast(message);

      const stale: string[] = [];
      response.responses.forEach((result, index) => {
        const code = result.error?.code;
        if (!code) return;
        const fid = fids[index];
        if (fid && STALE_TOKEN_CODES.has(code)) stale.push(fid);
        // Anything the OS rejects is logged (never the message body) so a
        // silently-undelivered push is diagnosable from the server logs.
        this.logger.warn({ code, fid, mode }, 'FCM rejected a send');
      });

      this.logger.info(
        {
          mode,
          sent: response.successCount,
          failed: response.failureCount,
          total: fids.length,
          pruned: stale.length,
        },
        'FCM multicast sent',
      );

      if (stale.length > 0) {
        this.logger.info(
          { mode, stale: stale.length, total: fids.length },
          'pruning unregistered FCM installations',
        );
      }
      return stale;
    } catch (error) {
      this.logger.warn({ err: error, mode, total: fids.length }, 'FCM send failed');
      return [];
    }
  }

  /**
   * Resolves credentials from inline env vars first, then a credentials file.
   * Returns `null` when neither is configured. The private key's literal `\n`
   * escapes (as stored in `.env`) are converted to real newlines so the PEM is
   * accepted by `cert()`.
   */
  private async loadCredentials(): Promise<ServiceAccount | null> {
    const fromEnv = this.credentialsFromEnv();
    if (fromEnv) return fromEnv;

    const file = this.config.FCM_CREDENTIALS_FILE;
    if (!file) return null;
    try {
      const raw = JSON.parse(await readFile(file, 'utf8')) as Record<string, unknown>;
      const clientEmail = stringValue(raw.client_email);
      const privateKey = stringValue(raw.private_key);
      if (!clientEmail || !privateKey) {
        this.logger.warn({ file }, 'FCM credentials file is missing client_email or private_key');
        return null;
      }
      return {
        projectId: this.config.FCM_PROJECT_ID ?? stringValue(raw.project_id),
        clientEmail,
        privateKey: normalizePrivateKey(privateKey),
      };
    } catch (error) {
      this.logger.warn({ err: error, file }, 'Could not read FCM credentials file');
      return null;
    }
  }

  private credentialsFromEnv(): ServiceAccount | null {
    const clientEmail = this.config.FIREBASE_CLIENT_EMAIL;
    const privateKey = this.config.FIREBASE_PRIVATE_KEY;
    if (!clientEmail || !privateKey) return null;
    return {
      projectId: this.config.FIREBASE_PROJECT_ID ?? this.config.FCM_PROJECT_ID,
      clientEmail,
      privateKey: normalizePrivateKey(privateKey),
    };
  }
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

/** A PEM key from `.env` arrives with escaped newlines; restore them. */
export function normalizePrivateKey(privateKey: string): string {
  return privateKey.includes('\\n') ? privateKey.replace(/\\n/g, '\n') : privateKey;
}
