import type { IncomingMessage } from 'node:http';
import type { Duplex } from 'node:stream';

import { WebSocketServer, WebSocket } from 'ws';

import type { Config } from '../config.js';
import type { Logger } from '../lib/logger.js';
import { ApiError } from '../lib/errors.js';
import { isUuidV4 } from '../lib/ids.js';
import { parseMessageContent } from '../lib/e2ee.js';
import { withSpan } from '../lib/tracing.js';
import { redisKeys, type Cache } from '../lib/redis.js';
import { verifyAccessToken } from '../lib/tokens.js';
import type { NotificationService } from '../lib/fcm.js';
import type { AppContext } from '../http/context.js';
import type { MessageRow } from '../domain/messages.js';
import type { Broker, BroadcastPayload, RoutedPayload } from '../lib/broker.js';
import { InboundConsumer, InboundProducer, type InboundSend } from './inbound.js';
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

const MAX_CONTENT_LENGTH = 16_384;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const HEARTBEAT_INTERVAL_MS = 25_000;
// A drained gateway reconnects clients with this code; the Flutter client
// treats any close as a reconnect and backs off, so drains are seamless.
const DRAIN_CLOSE_CODE = 1001;

export class ChatGateway {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
  private readonly sockets = new Map<string, Set<WebSocket>>();
  private readonly context = new WeakMap<WebSocket, SocketContext>();
  private readonly registry: ConnectionRegistry;
  private heartbeat: NodeJS.Timeout | null = null;
  private draining = false;
  private ready = false;
  // Async ingest (Phase 4): accepted sends go to `chat.inbound` and the
  // consumer does the persistence + fan-out. Off by default; the synchronous
  // path stays the default so single-node deployments keep working.
  private inboundProducer: InboundProducer | null = null;
  private inboundConsumer: InboundConsumer | null = null;
  // Close/connect handlers keep doing database work (unregistering presence,
  // persisting last-seen) after the socket is gone. Shutdown awaits these so
  // the pools are not closed underneath a half-finished write.
  private readonly pending = new Set<Promise<unknown>>();

  constructor(
    private readonly config: Config,
    private readonly ctx: AppContext,
    private readonly broker: Broker,
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
    // Attach the transport handlers before consuming, so a frame that arrives
    // immediately after the first subscribe is not processed against an empty
    // socket map.
    await this.broker.start({
      onRouted: (payload) => this.handleRoutedEvent(payload),
      onBroadcast: (payload) => this.handleBroadcast(payload),
    });

    this.heartbeat = setInterval(() => {
      void this.sweep();
    }, HEARTBEAT_INTERVAL_MS);

    if (this.config.GATEWAY_ASYNC_INGEST) {
      if (this.broker.kind !== 'kafka') {
        throw new Error('GATEWAY_ASYNC_INGEST requires BROKER=kafka');
      }
      this.inboundProducer = new InboundProducer(this.config);
      this.inboundConsumer = new InboundConsumer(this.config, this.logger, (outcome) =>
        this.deliverStored(outcome.message, outcome.duplicate, outcome.send),
      );
      await this.inboundConsumer.start(this.ctx);
    }

    this.ready = true;
    this.logger.info(
      { node: this.config.gatewayNodeId, broker: this.broker.kind },
      'chat gateway started',
    );
  }

  /** Readiness is false while starting and once a drain has begun. */
  isReady(): boolean {
    return this.ready && !this.draining;
  }

  isDraining(): boolean {
    return this.draining;
  }

  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    if (this.draining) {
      // 503 tells the load balancer to send the client to a healthy replica on
      // the retry instead of reconnecting it to a node that is going away.
      socket.write('HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n\r\n');
      socket.destroy();
      return;
    }

    try {
      const token = this.tokenFrom(request);
      const payload = verifyAccessToken(token, this.config);
      this.wss.handleUpgrade(request, socket, head, (ws) => {
        this.track(this.onConnection(ws, payload.sub, payload.device_id));
      });
    } catch (error) {
      const status = error instanceof ApiError ? error.status : 401;
      socket.write(`HTTP/1.1 ${status} ${status === 401 ? 'Unauthorized' : 'Error'}\r\n\r\n`);
      socket.destroy();
    }
  }

  /**
   * Graceful drain for rolling deploys and scale-in.
   *
   * New upgrades are refused (503) so the load balancer reroutes them, live
   * clients are closed with `1001 (going away)` which the Flutter client turns
   * into an exponential-backoff reconnect against another replica, and the
   * process waits for the sockets to acknowledge the close. Waiting instead of
   * tearing down avoids losing a frame that was already in flight.
   */
  async drain(timeoutMs = this.config.GATEWAY_DRAIN_TIMEOUT_MS): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    this.ready = false;
    this.logger.info({ node: this.config.gatewayNodeId }, 'gateway draining');

    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;

    const closed = new Promise<void>((resolve) => {
      let remaining = [...this.sockets.values()].reduce((sum, set) => sum + set.size, 0);
      if (remaining === 0) {
        resolve();
        return;
      }
      for (const set of this.sockets.values()) {
        for (const ws of set) {
          ws.once('close', () => {
            remaining -= 1;
            if (remaining === 0) resolve();
          });
          ws.close(DRAIN_CLOSE_CODE, 'server draining');
        }
      }
    });

    const timedOut = await Promise.race([
      closed.then(() => false),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(true), timeoutMs)),
    ]);
    if (timedOut) {
      this.logger.warn({ node: this.config.gatewayNodeId }, 'drain timed out; terminating sockets');
      for (const set of this.sockets.values()) {
        for (const ws of set) ws.terminate();
      }
    }

    this.sockets.clear();
  }

  async stop(): Promise<void> {
    await this.drain(0);
    // Terminating sockets emits `close` asynchronously, which is what enqueues
    // the unregister/presence work. Let those handlers run, then wait for them.
    for (let round = 0; round < 20; round += 1) {
      await new Promise<void>((resolve) => setImmediate(resolve));
      if (this.pending.size === 0) break;
      await Promise.allSettled([...this.pending]);
    }
    await this.broker.close();
    await this.inboundConsumer?.close();
    await this.inboundProducer?.close();
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
      this.track(this.onFrame(ws, data.toString()));
    });
    ws.on('close', () => {
      this.track(this.onClose(ws, userId, deviceId));
    });
    ws.on('error', (error) => {
      this.logger.debug({ err: error }, 'socket error');
    });

    await this.registry.register(userId, deviceId);
    await this.ctx.presence.touch(userId);
    // Only the first live device changes the peers' view from offline to
    // online; a second login of the same user is not a state transition.
    if ((await this.registry.liveDevices(userId)).length === 1) {
      await this.broadcastPresence(userId, true, null);
    }
  }

  private async onClose(ws: WebSocket, userId: string, deviceId: string): Promise<void> {
    const key = `${userId}:${deviceId}`;
    const set = this.sockets.get(key);
    set?.delete(ws);
    if (set && set.size === 0) {
      this.sockets.delete(key);
      await this.registry.unregister(userId, deviceId);
      // Presence is per user, not per device: going offline is a transition
      // only once the last device of the user has disconnected.
      if ((await this.registry.liveDevices(userId)).length === 0) {
        const lastSeen = await this.ctx.presence.markOffline(userId);
        await this.broadcastPresence(userId, false, lastSeen);
      }
    }
  }

  /**
   * Tells every user who shares a conversation with `userId` that their online
   * state changed. Goes through the broadcast channel so peers connected to any
   * gateway replica receive it.
   */
  private async broadcastPresence(
    userId: string,
    online: boolean,
    lastSeenAt: Date | null,
  ): Promise<void> {
    const peers = await this.ctx.presence.sharedPeerIds(userId);
    if (peers.length === 0) return;

    await this.broker.publishBroadcast({
      user_ids: peers,
      frame: {
        type: 'presence',
        user_id: userId,
        online,
        last_seen_at: lastSeenAt ? lastSeenAt.toISOString() : null,
      },
    });
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
        await this.ctx.presence.touch(userId);
      }
    }
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
          await this.ctx.presence.touch(context.userId);
          return;
        case 'send':
          await this.handleSend(context, frame as ClientFrame & { type: 'send' });
          return;
        case 'ack':
          await this.handleAck(context, frame as ClientFrame & { type: 'ack' });
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
    // The server cannot read an encrypted body, but it must not relay a corrupt
    // one: a prefixed envelope that fails to parse is a client bug, and
    // delivering it as text would silently corrupt the conversation.
    try {
      parseMessageContent(content);
    } catch {
      throw new ApiError('validation_error', 'Malformed end-to-end encrypted message');
    }
    if (!(await this.ctx.conversations.isMember(conversationId, context.userId))) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }

    if (this.inboundProducer) {
      // Async ingest: validate here, then hand off. The `sent` ack is emitted
      // by deliverStored() once the consumer has allocated the real `seq`, so
      // the client still gets an ordered acknowledgement, just asynchronously.
      const send: InboundSend = {
        conversation_id: conversationId,
        sender_id: context.userId,
        device_id: context.deviceId,
        client_msg_id: clientMsgId,
        msg_type: msgType,
        content,
        accepted_at: new Date().toISOString(),
      };
      await this.inboundProducer.publish(send);
      return;
    }

    const { message, duplicate } = await this.ctx.messages.append({
      conversationId,
      senderId: context.userId,
      clientMsgId,
      type: msgType,
      content,
    });

    await this.deliverStored(message, duplicate, {
      conversation_id: conversationId,
      sender_id: context.userId,
      device_id: context.deviceId,
      client_msg_id: clientMsgId,
      msg_type: msgType,
      content,
    });
  }

  /**
   * Fans a stored message out to its recipients. Shared by the synchronous send
   * path and the async inbound consumer, so both emit the same frames.
   */
  private async deliverStored(
    message: MessageRow,
    duplicate: boolean,
    send: InboundSend,
  ): Promise<void> {
    return withSpan(
      'message.fanout',
      {
        conversation_id: message.conversation_id,
        seq: message.seq,
        duplicate,
        async_ingest: this.inboundProducer !== null,
      },
      () => this.deliverStoredInner(message, duplicate, send),
    );
  }

  private async deliverStoredInner(
    message: MessageRow,
    duplicate: boolean,
    send: InboundSend,
  ): Promise<void> {
    // Async sends come back through the consumer on whichever replica owns the
    // partition, so the ack must be routed to the originating device rather
    // than written to a local socket.
    const origin = this.deviceSocket(send.sender_id, send.device_id);

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

    const ack = {
      type: 'status',
      conversation_id: message.conversation_id,
      client_msg_id: message.client_msg_id,
      seq: message.seq,
      status: 'sent',
    };

    // `sent` is only ever delivered to the originating socket.
    if (origin) {
      this.send(origin, ack);
    } else {
      await this.routeToDevice(send.sender_id, send.device_id, ack);
    }

    // A duplicate retry is already persisted and fanned out earlier, including
    // to the sender's other devices; re-broadcasting would deliver it twice.
    if (duplicate) return;

    // Multi-device: the sender's *other* devices receive the message too so
    // their local history stays in sync without a REST round trip. The
    // originating device already has the `sent` ack, so it must not get a
    // duplicate `message` frame.
    await this.deliverToOtherDevices(send.sender_id, send.device_id, messageEvent);

    const members = await this.ctx.members.ids(message.conversation_id);
    const conversation = await this.ctx.conversations.getRow(message.conversation_id);

    // Fan-out on write. Recipients are independent, so deliver in parallel
    // instead of serializing a round trip per member in a 500-person group.
    await Promise.all(
      members
        .filter((memberId) => memberId !== send.sender_id)
        .map(async (memberId) => {
          await this.route(memberId, messageEvent);
          await this.maybeNotify(memberId, message, conversation?.type === 'group');
        }),
    );
  }

  private deviceSocket(userId: string, deviceId: string): WebSocket | null {
    const set = this.sockets.get(`${userId}:${deviceId}`);
    if (!set) return null;
    for (const ws of set) return ws;
    return null;
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
      await this.broadcastGroupRead(conversationId, context, readSeq);
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
    await this.route(message.sender_id, statusEvent);

    // Other devices of the acking user keep their local read cursor in sync so
    // a conversation read on one device clears its unread badge everywhere.
    if (status === 'read' && readSeq !== null) {
      await this.deliverToOtherDevices(context.userId, context.deviceId, {
        type: 'read_state',
        conversation_id: conversationId,
        seq: readSeq,
      });
    }
  }

  /**
   * Emits a `read_receipt` frame to the sender of the latest messages, carrying
   * the aggregated count of members who have read up to the reader's cursor.
   */
  private async broadcastGroupRead(
    conversationId: string,
    reader: SocketContext,
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
      reader_id: reader.userId,
      seq: readSeq,
      sender_id: target.sender_id,
      client_msg_id: target.client_msg_id,
      read_count: stats.readCount,
      member_count: stats.memberCount,
    };

    await this.route(target.sender_id, frame);

    // Every other device of the reader keeps its own read cursor in sync.
    await this.deliverToOtherDevices(reader.userId, reader.deviceId, {
      type: 'read_state',
      conversation_id: conversationId,
      seq: readSeq,
    });
  }

  /**
   * Delivers a frame to every socket of `userId`. Local sockets are written
   * directly; devices owned by other nodes are reached through the broker.
   */
  private async route(userId: string, frame: Record<string, unknown>): Promise<void> {
    for (const ws of this.socketsFor(userId)) this.send(ws, frame);

    const devices = await this.registry.liveDevices(userId);
    const nodes = new Set<string>();
    for (const deviceId of devices) {
      const node = await this.ctx.redis.get(redisKeys.connection(userId, deviceId));
      if (node && node !== this.config.gatewayNodeId) nodes.add(node);
    }

    for (const node of nodes) {
      await this.broker.publishToNode(
        node,
        { userId, frame },
        conversationKey(frame),
      );
    }
  }

  /** Delivers a frame to exactly one device, wherever it is connected. */
  private async routeToDevice(
    userId: string,
    deviceId: string,
    frame: Record<string, unknown>,
  ): Promise<void> {
    const local = this.deviceSocket(userId, deviceId);
    if (local) {
      this.send(local, frame);
      return;
    }

    const node = await this.ctx.redis.get(redisKeys.connection(userId, deviceId));
    if (node && node !== this.config.gatewayNodeId) {
      await this.broker.publishToNode(
        node,
        { userId, frame, onlyDevice: deviceId },
        conversationKey(frame),
      );
    }
  }

  /**
   * Delivers a frame to every connected device of `userId` except the device
   * that originated it. Remote devices are reached through their node's broker
   * channel, carrying an `excludeDevice` so a node never echoes the frame back
   * to the originating socket.
   */
  private async deliverToOtherDevices(
    userId: string,
    excludeDeviceId: string,
    frame: Record<string, unknown>,
  ): Promise<void> {
    for (const [key, set] of this.sockets) {
      if (!key.startsWith(`${userId}:`)) continue;
      if (key === `${userId}:${excludeDeviceId}`) continue;
      for (const ws of set) this.send(ws, frame);
    }

    const devices = await this.registry.liveDevices(userId);
    const nodes = new Set<string>();
    for (const deviceId of devices) {
      if (deviceId === excludeDeviceId) continue;
      const node = await this.ctx.redis.get(redisKeys.connection(userId, deviceId));
      if (node && node !== this.config.gatewayNodeId) nodes.add(node);
    }

    for (const node of nodes) {
      await this.broker.publishToNode(
        node,
        { userId, frame, excludeDevice: excludeDeviceId },
        conversationKey(frame),
      );
    }
  }

  private handleRoutedEvent(payload: RoutedPayload): void {
    for (const [key, set] of this.sockets) {
      if (!key.startsWith(`${payload.userId}:`)) continue;
      if (payload.excludeDevice && key === `${payload.userId}:${payload.excludeDevice}`) continue;
      if (payload.onlyDevice && key !== `${payload.userId}:${payload.onlyDevice}`) continue;
      for (const ws of set) this.send(ws, payload.frame);
    }
  }

  /** Broadcast frames target a set of users that may be spread over every node. */
  private handleBroadcast(payload: BroadcastPayload): void {
    for (const userId of payload.user_ids) {
      for (const ws of this.socketsFor(userId)) {
        this.send(ws, payload.frame);
      }
    }
  }

  private socketsFor(userId: string): WebSocket[] {
    const sockets: WebSocket[] = [];
    for (const [key, set] of this.sockets) {
      if (key.startsWith(`${userId}:`)) sockets.push(...set);
    }
    return sockets;
  }

  /** Registers async fire-and-forget work so shutdown can wait for it. */
  private track(work: Promise<unknown>): void {
    this.pending.add(work);
    void work.finally(() => this.pending.delete(work)).catch(() => undefined);
  }

  private send(ws: WebSocket, frame: Record<string, unknown>): void {
    if (ws.readyState !== WebSocket.OPEN) return;
    // Drop slow consumers rather than buffering without bound.
    if (ws.bufferedAmount > MAX_BUFFERED_BYTES) return;
    ws.send(JSON.stringify(frame));
  }
}

/**
 * Partition key for broker ordering. Frames for one conversation must share a
 * partition; user-only frames fall back to the recipient id.
 */
function conversationKey(frame: Record<string, unknown>): string {
  const conversationId = frame.conversation_id;
  if (typeof conversationId === 'string') return `c:${conversationId}`;
  const userId = frame.user_id;
  if (typeof userId === 'string') return `u:${userId}`;
  return 'control';
}

/** Exposed for the broker ingestion worker and tests. */
export { conversationKey };
export type { RoutedPayload, BroadcastPayload };
