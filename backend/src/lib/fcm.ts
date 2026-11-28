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

export type CallPushEventType =
  | 'call_invite'
  | 'call_cancel'
  | 'call_ended'
  | 'group_call_started';

export type CallPushPayload = {
  type: CallPushEventType;
  callId: string;
  conversationId: string;
  conversationType: 'direct' | 'group';
  conversationName: string;
  callType: '1on1' | 'group';
  mediaType: 'voice' | 'video';
  callerId: string;
  callerName: string;
  recipientUserId: string;
  expiresAtMs?: number;
  reason?: string;
};

/**
 * Builds the `push_schema: "2"` string-only FCM `data` map for call signaling.
 * Never includes LiveKit JWT tokens or room secrets.
 */
export function buildCallPushMap(payload: CallPushPayload): Record<string, string> {
  return {
    push_schema: '2',
    type: payload.type,
    call_id: payload.callId,
    conversation_id: payload.conversationId,
    conversation_type: payload.conversationType,
    conversation_name: payload.conversationName,
    call_type: payload.callType,
    media_type: payload.mediaType,
    caller_id: payload.callerId,
    caller_name: payload.callerName,
    recipient_user_id: payload.recipientUserId,
    expires_at: payload.expiresAtMs !== undefined ? String(payload.expiresAtMs) : '',
    reason: payload.reason ?? '',
  };
}

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
]);

const FCM_MAX_BATCH_SIZE = 500;

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

  /**
   * Sends a high-priority data-only FCM message for incoming call signaling,
   * cancellation, or group call announcements. Uses a 45 s TTL so stale rings
   * are never delivered minutes later when a phone comes back online.
   */
  async notifyCallEvent(fids: string[], payload: CallPushPayload): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    return this.sendMulticast(fids, 'data_only', {
      fids,
      data: buildCallPushMap(payload),
      android: {
        priority: 'high',
        ttl: 45_000,
      },
    });
  }

  private async sendMulticast(
    fids: string[],
    mode: 'legacy' | 'data_only',
    message: Parameters<Messaging['sendEachForMulticast']>[0],
  ): Promise<string[]> {
    if (!this.messaging || fids.length === 0) return [];

    const dataMap = 'data' in message && message.data ? message.data : undefined;
    const dataKeys = dataMap ? Object.keys(dataMap) : [];
    const dataBytes = dataMap ? Buffer.byteLength(JSON.stringify(dataMap), 'utf8') : 0;
    const contentOmitted = dataMap?.content_omitted === 'true';

    const stale: string[] = [];
    let sent = 0;
    let failed = 0;

    for (let offset = 0; offset < fids.length; offset += FCM_MAX_BATCH_SIZE) {
      const chunk = fids.slice(offset, offset + FCM_MAX_BATCH_SIZE);
      try {
        const response = await this.messaging.sendEachForMulticast({
          ...message,
          fids: chunk,
        });

        sent += response.successCount;
        failed += response.failureCount;

        response.responses.forEach((result, index) => {
          const code = result.error?.code;
          if (!code) return;
          const fid = chunk[index];
          if (code === 'messaging/invalid-argument') {
            this.logger.error(
              { code, fid, mode, data_keys: dataKeys, data_bytes: dataBytes },
              'FCM rejected payload as invalid-argument; keeping device token',
            );
            return;
          }
          if (fid && STALE_TOKEN_CODES.has(code)) stale.push(fid);
          this.logger.warn({ code, fid, mode }, 'FCM rejected a send');
        });
      } catch (error) {
        failed += chunk.length;
        this.logger.warn({ err: error, mode, total: chunk.length }, 'FCM send failed');
      }
    }

    this.logger.info(
      {
        mode,
        sent,
        failed,
        total: fids.length,
        pruned: stale.length,
        content_omitted: contentOmitted,
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
