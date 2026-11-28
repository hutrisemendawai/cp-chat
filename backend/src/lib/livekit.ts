import {
  AccessToken,
  RoomServiceClient,
  WebhookReceiver,
  type WebhookEvent,
} from 'livekit-server-sdk';

import type { Config } from '../config.js';
import { ApiError } from './errors.js';
import type { Logger } from './logger.js';

export type CreateLiveKitRoomOptions = {
  maxParticipants: number;
  emptyTimeout?: number;
  departureTimeout?: number;
};

export type MintLiveKitTokenInput = {
  roomName: string;
  userId: string;
  displayName: string;
  metadata?: string;
};

export type MintedLiveKitToken = {
  token: string;
  expiresIn: number;
};

export interface LiveKitClient {
  readonly enabled: boolean;
  readonly publicUrl: string;
  createRoom(roomName: string, options: CreateLiveKitRoomOptions): Promise<void>;
  deleteRoom(roomName: string): Promise<void>;
  listRooms(names?: string[]): Promise<string[]>;
  mintToken(input: MintLiveKitTokenInput): Promise<MintedLiveKitToken>;
  verifyWebhook(rawBody: string, authHeader: string): Promise<WebhookEvent>;
}

/**
 * Thin wrapper around `livekit-server-sdk` (`RoomServiceClient`, `AccessToken`,
 * `WebhookReceiver`). Gracefully disables itself when `LIVEKIT_API_KEY` or
 * `LIVEKIT_API_SECRET` is unset so messaging-only deployments and CI suites
 * run without a LiveKit daemon.
 */
export class LiveKitService implements LiveKitClient {
  private readonly apiKey: string | null;
  private readonly apiSecret: string | null;
  private readonly roomService: RoomServiceClient | null;
  private readonly webhookReceiver: WebhookReceiver | null;

  constructor(
    private readonly config: Config,
    private readonly logger: Logger,
  ) {
    const key = config.LIVEKIT_API_KEY?.trim() || null;
    const secret = config.LIVEKIT_API_SECRET?.trim() || null;

    if (key && secret) {
      this.apiKey = key;
      this.apiSecret = secret;
      this.roomService = new RoomServiceClient(config.LIVEKIT_URL, key, secret);
      this.webhookReceiver = new WebhookReceiver(key, secret);
    } else {
      this.apiKey = null;
      this.apiSecret = null;
      this.roomService = null;
      this.webhookReceiver = null;
    }
  }

  get enabled(): boolean {
    return this.apiKey !== null && this.apiSecret !== null;
  }

  get publicUrl(): string {
    return this.config.LIVEKIT_PUBLIC_URL;
  }

  async createRoom(roomName: string, options: CreateLiveKitRoomOptions): Promise<void> {
    if (!this.roomService) {
      throw new ApiError('calls_unavailable', 'Voice and video calling is not configured');
    }
    try {
      await this.roomService.createRoom({
        name: roomName,
        maxParticipants: options.maxParticipants,
        emptyTimeout: options.emptyTimeout ?? 45,
        departureTimeout: options.departureTimeout ?? 20,
      });
    } catch (error) {
      this.logger.error({ err: error, room_name: roomName }, 'LiveKit createRoom failed');
      throw new ApiError('calls_unavailable', 'Could not initialize call room');
    }
  }

  async deleteRoom(roomName: string): Promise<void> {
    if (!this.roomService) return;
    try {
      await this.roomService.deleteRoom(roomName);
    } catch (error) {
      // Room may already have expired or never opened; treat 404/not-found as idempotent.
      const message = error instanceof Error ? error.message.toLowerCase() : '';
      if (message.includes('not found') || message.includes('404') || message.includes('does not exist')) {
        return;
      }
      this.logger.warn({ err: error, room_name: roomName }, 'LiveKit deleteRoom failed');
    }
  }

  async listRooms(names?: string[]): Promise<string[]> {
    if (!this.roomService) return [];
    const rooms = await this.roomService.listRooms(names);
    return rooms.map((room) => room.name);
  }

  async mintToken(input: MintLiveKitTokenInput): Promise<MintedLiveKitToken> {
    if (!this.apiKey || !this.apiSecret) {
      throw new ApiError('calls_unavailable', 'Voice and video calling is not configured');
    }
    const ttl = this.config.LIVEKIT_TOKEN_TTL_SECONDS;
    const token = new AccessToken(this.apiKey, this.apiSecret, {
      identity: input.userId,
      name: input.displayName,
      metadata: input.metadata,
      ttl,
    });
    token.addGrant({
      roomJoin: true,
      room: input.roomName,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      roomCreate: false,
    });
    return {
      token: await token.toJwt(),
      expiresIn: ttl,
    };
  }

  async verifyWebhook(rawBody: string, authHeader: string): Promise<WebhookEvent> {
    if (!this.webhookReceiver) {
      throw new ApiError('calls_unavailable', 'LiveKit webhook receiver is not configured');
    }
    if (!authHeader) {
      throw new ApiError('unauthorized', 'Missing LiveKit webhook Authorization header');
    }
    try {
      return await this.webhookReceiver.receive(rawBody, authHeader);
    } catch (error) {
      this.logger.warn({ err: error }, 'LiveKit webhook signature verification failed');
      throw new ApiError('unauthorized', 'Invalid LiveKit webhook signature');
    }
  }
}
