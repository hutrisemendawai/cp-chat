import type { IncomingMessage } from 'node:http';
import type { Duplex } from 'node:stream';

import { WebSocketServer, WebSocket } from 'ws';

import type { Config } from '../config.js';
import type { Logger } from '../lib/logger.js';
import { ApiError } from '../lib/errors.js';
import { isUuidV4 } from '../lib/ids.js';
import { redisKeys, type Cache } from '../lib/redis.js';
import { verifyAccessToken } from '../lib/tokens.js';
import type { NotificationService } from '../lib/fcm.js';
import type { AppContext } from '../http/context.js';
import type { MessageRow } from '../domain/messages.js';
import { ConnectionRegistry } from './connection-registry.js';

type ClientFrame =
  | { type: 'send'; conversation_id: string; client_msg_id: string; msg_type: 'text' | 'image' | 'file'; content: string }
  | { type: 'ack'; conversation_id: string; seq: number; status: 'delivered' | 'read' }
  | { type: 'ping' };

type SocketContext = {
  userId: string;
  deviceId: string;
  alive: boolean;
};

type RoutedEvent =
  | { kind: 'message'; userId: string; frame: Record<string, unknown> }
  | { kind: 'status'; userId: string; frame: Record<string, unknown> };

const MAX_CONTENT_LENGTH = 16_384;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const HEARTBEAT_INTERVAL_MS = 25_000;

export class ChatGateway {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  private readonly sockets = new Map<string, Set<WebSocket>>();
  private readonly context = new WeakMap<WebSocket, SocketContext>();
  private readonly registry: ConnectionRegistry;
  private heartbeat: NodeJS.Timeout | null = null;
  private subscriber: Cache | null = null;

  constructor(
    private readonly config: Config,
    private readonly ctx: AppContext,
    private readonly notifications: NotificationService,
    private readonly logger: Logger,
  ) {
    this.registry = new ConnectionRegistry(
      ctx.redis,
      config.gatewayNodeId,
      config.CONNECTION_TTL_SECONDS,
    );
  }

  async start(): Promise<void> {
    this.subscriber = this.ctx.redis.duplicate();
    await this.subscriber.subscribe(
      redisKeys.channelForNode(this.config.gatewayNodeId),
      redisKeys.allNodesChannel,
    );
    this.subscriber.on('message', (channel, raw) => {
      if (channel === redisKeys.allNodesChannel) {
        this.handleBroadcast(raw);
        return;
      }
      this.handleRoutedEvent(raw);
    });

    this.heartbeat = setInterval(() => {
      void this.sweep();
    }, HEARTBEAT_INTERVAL_MS);

    this.logger.info({ node: this.config.gatewayNodeId }, 'chat gateway started');
  }

  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    try {
      const token = this.tokenFrom(request);
      const payload = verifyAccessToken(token, this.config);
      this.wss.handleUpgrade(request, socket, head, (ws) => {
        void this.onConnection(ws, payload.sub, payload.device_id);
      });
    } catch (error) {
      const status = error instanceof ApiError ? error.status : 401;
      socket.write(`HTTP/1.1 ${status} ${status === 401 ? 'Unauthorized' : 'Error'}\r\n\r\n`);
      socket.destroy();
    }
  }

  async stop(): Promise<void> {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;

    for (const sockets of this.sockets.values()) {
      for (const ws of sockets) ws.close(1001, 'server shutting down');
    }
    this.sockets.clear();
    await this.subscriber?.quit();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
  }

  private tokenFrom(request: IncomingMessage): string {
    const header = request.headers.authorization;
    if (header?.startsWith('Bearer ')) return header.slice('Bearer '.length).trim();

    const url = new URL(request.url ?? '/', 'http://gateway.local');
    const queryToken = url.searchParams.get('token');
    if (!queryToken) throw new ApiError('unauthorized', 'Missing access token');
    return queryToken;
  }

  private async onConnection(ws: WebSocket, userId: string, deviceId: string): Promise<void> {
    this.context.set(ws, { userId, deviceId, alive: true });
    const key = `${userId}:${deviceId}`;
    const set = this.sockets.get(key) ?? new Set<WebSocket>();
    set.add(ws);
    this.sockets.set(key, set);

    // Attach listeners before the first `await`: a client may send frames
    // immediately after the handshake, and they must not be dropped while the
    // Redis registry is being written.
    ws.on('pong', () => {
      const context = this.context.get(ws);
      if (context) context.alive = true;
    });
    ws.on('message', (data) => {
      void this.onFrame(ws, data.toString());
    });
    ws.on('close', () => {
      void this.onClose(ws, userId, deviceId);
    });
    ws.on('error', (error) => {
      this.logger.debug({ err: error }, 'socket error');
    });

    await this.registry.register(userId, deviceId);
    await this.touchPresence(userId);
  }

  private async onClose(ws: WebSocket, userId: string, deviceId: string): Promise<void> {
    const key = `${userId}:${deviceId}`;
    const set = this.sockets.get(key);
    set?.delete(ws);
    if (set && set.size === 0) {
      this.sockets.delete(key);
      await this.registry.unregister(userId, deviceId);
      // Presence stays until its TTL expires: the user may still be connected
      // from another device, and a quick reconnect should not flap the status.
    }
  }

  private async sweep(): Promise<void> {
    for (const [key, set] of this.sockets) {
      for (const ws of set) {
        const context = this.context.get(ws);
        if (!context) continue;
        if (!context.alive) {
          ws.terminate();
          continue;
        }
        context.alive = false;
        ws.ping();
        const [userId, deviceId] = key.split(':') as [string, string];
        await this.registry.refresh(userId, deviceId);
        await this.touchPresence(userId);
      }
    }
  }

  private async touchPresence(userId: string): Promise<void> {
    await this.ctx.redis.set(
      redisKeys.presenceKey(userId),
      Date.now().toString(),
      'EX',
      this.config.PRESENCE_TTL_SECONDS,
    );
  }

  private async onFrame(ws: WebSocket, raw: string): Promise<void> {
    const context = this.context.get(ws);
    if (!context) return;

    let frame: Record<string, unknown>;
    try {
      const decoded = JSON.parse(raw);
      if (typeof decoded !== 'object' || decoded === null) return;
      frame = decoded as Record<string, unknown>;
    } catch {
      this.send(ws, { type: 'error', code: 'invalid_frame', message: 'Frame is not valid JSON' });
      return;
    }

    try {
      switch (frame.type) {
        case 'ping':
          this.send(ws, { type: 'pong' });
          await this.touchPresence(context.userId);
          return;
        case 'send':
          await this.handleSend(ws, context, frame as ClientFrame & { type: 'send' });
          return;
        case 'ack':
          await this.handleAck(ws, context, frame as ClientFrame & { type: 'ack' });
          return;
        default:
          // Unknown client events are ignored by contract.
          return;
      }
    } catch (error) {
      const apiError = error instanceof ApiError ? error : null;
      this.logger.warn({ err: error }, 'frame handling failed');
      this.send(ws, {
        type: 'error',
        code: apiError?.code ?? 'internal_error',
        message: apiError?.message ?? 'Could not process the event',
      });
    }
  }

  private async handleSend(
    ws: WebSocket,
    context: SocketContext,
    frame: { conversation_id?: unknown; client_msg_id?: unknown; msg_type?: unknown; content?: unknown },
  ): Promise<void> {
    const conversationId = typeof frame.conversation_id === 'string' ? frame.conversation_id : '';
    const clientMsgId = typeof frame.client_msg_id === 'string' ? frame.client_msg_id : '';
    const msgType = frame.msg_type;
    const content = typeof frame.content === 'string' ? frame.content : '';

    if (!conversationId || !clientMsgId) {
      throw new ApiError('validation_error', 'conversation_id and client_msg_id are required');
    }
    if (!isUuidV4(clientMsgId)) {
      throw new ApiError('validation_error', 'client_msg_id must be a UUIDv4');
    }
    if (msgType !== 'text' && msgType !== 'image' && msgType !== 'file') {
      throw new ApiError('validation_error', 'msg_type must be text, image or file');
    }
    if (msgType === 'text' && content.trim().length === 0) {
      throw new ApiError('validation_error', 'Message content cannot be empty');
    }
    if (content.length > MAX_CONTENT_LENGTH) {
      throw new ApiError('validation_error', 'Message content is too large');
    }
    if (!(await this.ctx.conversations.isMember(conversationId, context.userId))) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }

    const { message, duplicate } = await this.ctx.messages.append({
      conversationId,
      senderId: context.userId,
      clientMsgId,
      type: msgType,
      content,
    });

    const messageEvent = {
      type: 'message',
      conversation_id: message.conversation_id,
      message_id: message.id,
      seq: message.seq,
      sender_id: message.sender_id,
      client_msg_id: message.client_msg_id,
      msg_type: message.type,
      content: message.content,
      created_at: message.created_at.toISOString(),
    };

    // `sent` is only ever delivered to the originating socket.
    this.send(ws, {
      type: 'status',
      conversation_id: message.conversation_id,
      client_msg_id: message.client_msg_id,
      seq: message.seq,
      status: 'sent',
    });

    // A duplicate retry is already persisted and fanned out; re-broadcasting
    // would deliver it twice.
    if (duplicate) return;

    const members = await this.ctx.members.ids(conversationId);
    const conversation = await this.ctx.conversations.getRow(conversationId);

    // Fan-out on write. Recipients are independent, so deliver in parallel
    // instead of serializing a round trip per member in a 500-person group.
    await Promise.all(
      members
        .filter((memberId) => memberId !== context.userId)
        .map(async (memberId) => {
          await this.route(memberId, { kind: 'message', userId: memberId, frame: messageEvent });
          await this.maybeNotify(memberId, message, conversation?.type === 'group');
        }),
    );
  }

  private async maybeNotify(
    userId: string,
    message: MessageRow,
    isGroup: boolean,
  ): Promise<void> {
    if (!this.notifications.enabled) return;
    const onlineDevices = await this.registry.liveDevices(userId);
    if (onlineDevices.length > 0) return;

    const tokens = await this.ctx.devices.tokensForUser(userId);
    if (tokens.length === 0) return;

    const sender = await this.ctx.users.findById(message.sender_id);
    const senderName = sender?.name ?? 'New message';
    const body = message.type === 'text' ? message.content : 'Sent an attachment';

    const stale = await this.notifications.notify(
      tokens.map((token) => token.fcm_token),
      {
        title: isGroup ? `${senderName} (group)` : senderName,
        body,
        conversationId: message.conversation_id,
        messageId: message.id,
      },
    );

    for (const token of stale) {
      await this.ctx.db.query(`DELETE FROM device_tokens WHERE fcm_token = $1`, [token]);
    }
  }

  private async handleAck(
    ws: WebSocket,
    context: SocketContext,
    frame: { conversation_id?: unknown; seq?: unknown; status?: unknown },
  ): Promise<void> {
    const conversationId = typeof frame.conversation_id === 'string' ? frame.conversation_id : '';
    const seq = typeof frame.seq === 'number' ? frame.seq : Number(frame.seq);
    const status = frame.status;

    if (!conversationId || !Number.isInteger(seq) || seq <= 0) {
      throw new ApiError('validation_error', 'conversation_id and a positive seq are required');
    }
    if (status !== 'delivered' && status !== 'read') {
      throw new ApiError('validation_error', 'status must be delivered or read');
    }
    if (!(await this.ctx.conversations.isMember(conversationId, context.userId))) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }

    const conversation = await this.ctx.conversations.getRow(conversationId);

    // Per-message delivered receipts would write one row per member per message
    // in a group; groups track read cursors instead.
    if (status === 'delivered' && conversation?.type === 'group') {
      return;
    }

    const message =
      status === 'delivered'
        ? await this.ctx.messages.markDeliveredBySeq(conversationId, seq, context.userId)
        : await this.ctx.messages.findBySeq(conversationId, seq);
    if (!message) return;

    let readSeq: number | null = null;
    if (status === 'read') {
      readSeq = await this.ctx.messages.markRead(conversationId, context.userId, message.seq);
    }

    // In a group the sender needs an aggregate ("read by N"), not one event per
    // member: broadcasting every reader's cursor would be O(members) noise.
    if (status === 'read' && conversation?.type === 'group' && readSeq !== null) {
      await this.broadcastGroupRead(conversationId, context.userId, readSeq);
      return;
    }

    const statusEvent = {
      type: 'status',
      conversation_id: conversationId,
      client_msg_id: message.client_msg_id,
      seq: message.seq,
      status,
    };

    // The sender (possibly on another device of theirs) needs the update.
    await this.route(message.sender_id, {
      kind: 'status',
      userId: message.sender_id,
      frame: statusEvent,
    });

    // Other devices of the acking user keep their local read cursor in sync.
    if (status === 'read') {
      for (const deviceId of await this.registry.liveDevices(context.userId)) {
        if (deviceId === context.deviceId) continue;
        this.deliverToDevice(context.userId, deviceId, statusEvent);
      }
    }
  }

  /**
   * Emits a `read_receipt` frame to the sender of the latest messages, carrying
   * the aggregated count of members who have read up to the reader's cursor.
   */
  private async broadcastGroupRead(
    conversationId: string,
    readerId: string,
    readSeq: number,
  ): Promise<void> {
    const target = await this.ctx.messages.findBySeq(conversationId, readSeq);
    if (!target) return;

    // Counts members other than the original sender who have read up to the
    // reader's cursor, so the reader is included in the tally.
    const stats = await this.ctx.conversations.readStats(
      conversationId,
      readSeq,
      target.sender_id,
    );

    const frame = {
      type: 'read_receipt',
      conversation_id: conversationId,
      reader_id: readerId,
      seq: readSeq,
      sender_id: target.sender_id,
      client_msg_id: target.client_msg_id,
      read_count: stats.readCount,
      member_count: stats.memberCount,
    };

    await this.route(target.sender_id, {
      kind: 'status',
      userId: target.sender_id,
      frame,
    });

    // Every other device of the reader keeps its own read cursor in sync.
    for (const deviceId of await this.registry.liveDevices(readerId)) {
      this.deliverToDevice(readerId, deviceId, {
        type: 'status',
        conversation_id: conversationId,
        client_msg_id: target.client_msg_id,
        seq: readSeq,
        status: 'read',
      });
    }
  }

  /**
   * Publishes to the recipient's gateway node over Redis. If Redis says the
   * user is connected but no node consumes the event, the local deliver path
   * still tries in-process sockets (single-node deployments).
   */
  private async route(userId: string, event: RoutedEvent): Promise<void> {
    const localSockets = this.socketsFor(userId);
    if (localSockets.length > 0) {
      for (const ws of localSockets) this.send(ws, event.frame);
    }

    const remotePayload = JSON.stringify({ userId, frame: event.frame });
    const devices = await this.registry.liveDevices(userId);
    const nodes = new Set<string>();
    for (const deviceId of devices) {
      const node = await this.ctx.redis.get(redisKeys.connection(userId, deviceId));
      if (node && node !== this.config.gatewayNodeId) nodes.add(node);
    }

    for (const node of nodes) {
      await this.ctx.redis.publish(redisKeys.channelForNode(node), remotePayload);
    }
  }

  private handleRoutedEvent(raw: string): void {
    try {
      const parsed = JSON.parse(raw) as { userId: string; frame: Record<string, unknown> };
      for (const ws of this.socketsFor(parsed.userId)) {
        this.send(ws, parsed.frame);
      }
    } catch (error) {
      this.logger.debug({ err: error }, 'dropped malformed routed event');
    }
  }

  /** Broadcast frames target a set of users that may be spread over every node. */
  private handleBroadcast(raw: string): void {
    try {
      const parsed = JSON.parse(raw) as {
        user_ids: string[];
        frame: Record<string, unknown>;
      };
      for (const userId of parsed.user_ids) {
        for (const ws of this.socketsFor(userId)) {
          this.send(ws, parsed.frame);
        }
      }
    } catch (error) {
      this.logger.debug({ err: error }, 'dropped malformed broadcast event');
    }
  }

  private deliverToDevice(userId: string, deviceId: string, frame: Record<string, unknown>): void {
    for (const ws of this.sockets.get(`${userId}:${deviceId}`) ?? []) {
      this.send(ws, frame);
    }
  }

  private socketsFor(userId: string): WebSocket[] {
    const sockets: WebSocket[] = [];
    for (const [key, set] of this.sockets) {
      if (key.startsWith(`${userId}:`)) sockets.push(...set);
    }
    return sockets;
  }

  private send(ws: WebSocket, frame: Record<string, unknown>): void {
    if (ws.readyState !== WebSocket.OPEN) return;
    // Drop slow consumers rather than buffering without bound.
    if (ws.bufferedAmount > MAX_BUFFERED_BYTES) return;
    ws.send(JSON.stringify(frame));
  }
}
