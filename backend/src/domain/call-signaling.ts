import type { Config } from '../config.js';
import type { Broker } from '../lib/broker.js';
import { ApiError } from '../lib/errors.js';
import type { CallPushEventType, NotificationService } from '../lib/fcm.js';
import type { LiveKitClient } from '../lib/livekit.js';
import type { Logger } from '../lib/logger.js';
import { redisKeys, type Cache } from '../lib/redis.js';
import { ConnectionRegistry } from '../gateway/connection-registry.js';
import type { CallMediaType, CallRepository, CallSummary } from './calls.js';
import type { DeviceRepository } from './devices.js';
import type { UserRepository } from './users.js';

const ACTIVE_CALL_CACHE_TTL_SECONDS = 3600;
const USER_CALL_TTL_SECONDS = 3600;

export type CallJoinResponse = {
  call: CallSummary;
  livekit_url: string;
  token: string;
  expires_in: number;
  joined_existing: boolean;
};

/**
 * Coordinates call state transitions across Postgres (`CallRepository`),
 * LiveKit (`LiveKitClient`), Redis busy/banner caches, WebSocket signaling
 * (`Broker`), and high-priority data-only FCM pushes (`NotificationService`).
 */
export class CallSignalingService {
  private readonly connections: ConnectionRegistry;

  constructor(
    private readonly config: Config,
    private readonly calls: CallRepository,
    private readonly livekit: LiveKitClient,
    private readonly users: UserRepository,
    private readonly devices: DeviceRepository,
    private readonly notifications: NotificationService,
    private readonly broker: Broker,
    private readonly redis: Cache,
    private readonly logger: Logger,
  ) {
    this.connections = new ConnectionRegistry(
      redis,
      config.gatewayNodeId,
      config.CONNECTION_TTL_SECONDS,
    );
  }

  async startCall(input: {
    conversationId: string;
    callerId: string;
    deviceId: string;
    mediaType: CallMediaType;
  }): Promise<CallJoinResponse> {
    this.requireEnabled();

    const caller = await this.users.findById(input.callerId);
    if (!caller) {
      throw new ApiError('not_found', 'Caller account not found');
    }

    const outcome = await this.calls.startOrJoinConversationCall({
      conversationId: input.conversationId,
      callerId: input.callerId,
      mediaType: input.mediaType,
      ringTimeoutSeconds: this.config.CALL_RING_TIMEOUT_SECONDS,
      maxGroupParticipants: this.config.CALL_MAX_GROUP_PARTICIPANTS,
    });

    const { call } = outcome;

    // Create the LiveKit room before minting the first token (auto_create: false).
    if (!outcome.joinedExisting) {
      try {
        await this.livekit.createRoom(call.room_name, {
          maxParticipants:
            call.type === '1on1' ? 2 : this.config.CALL_MAX_GROUP_PARTICIPANTS,
          emptyTimeout: this.config.CALL_RING_TIMEOUT_SECONDS + 5,
          departureTimeout: 20,
        });
      } catch (error) {
        // Clean up the newly created DB call row so the conversation is not wedged.
        await this.calls.markRoomFinished(call.room_name, 'room_create_failed');
        throw error;
      }
    }

    const minted = await this.livekit.mintToken({
      roomName: call.room_name,
      userId: caller.id,
      displayName: caller.nickname ?? caller.name,
      metadata: JSON.stringify({
        avatar_url: caller.avatar_url,
        device_id: input.deviceId,
      }),
    });

    await this.markUserBusy(caller.id, call.id);
    await this.cacheActiveCall(call);

    if (call.type === '1on1' && outcome.peerId) {
      if (outcome.autoAcceptedCollision) {
        await this.publishBroadcast(
          [outcome.peerId],
          {
            type: 'call_accepted',
            call_id: call.id,
            conversation_id: call.conversation_id,
            accepted_by: caller.id,
          },
          call.conversation_id,
        );
      } else if (!outcome.joinedExisting) {
        const expiresAtIso = call.ring_expires_at?.toISOString() ?? null;
        const expiresAtMs = call.ring_expires_at?.getTime();

        await this.publishBroadcast(
          [outcome.peerId],
          {
            type: 'call_incoming',
            call_id: call.id,
            conversation_id: call.conversation_id,
            call_type: '1on1',
            media_type: call.media_type,
            room_name: call.room_name,
            caller: {
              id: caller.id,
              name: caller.nickname ?? caller.name,
              avatar_url: caller.avatar_url,
            },
            expires_at: expiresAtIso,
          },
          call.conversation_id,
        );

        await this.pushCallEvent({
          recipientUserIds: [outcome.peerId],
          type: 'call_invite',
          call,
          conversationType: 'direct',
          conversationName: '',
          callerId: caller.id,
          callerName: caller.nickname ?? caller.name,
          expiresAtMs,
          skipOnlineDevices: true,
          respectDnd: true,
        });
      }
    } else if (call.type === 'group') {
      const others = outcome.memberIds.filter((id) => id !== caller.id);
      if (!outcome.joinedExisting) {
        await this.publishBroadcast(
          outcome.memberIds,
          {
            type: 'group_call_started',
            call_id: call.id,
            conversation_id: call.conversation_id,
            conversation_name: outcome.conversationName ?? 'Group',
            media_type: call.media_type,
            started_by: {
              id: caller.id,
              name: caller.nickname ?? caller.name,
            },
            participant_count: call.participant_count,
            participant_ids: call.participant_ids,
          },
          call.conversation_id,
        );

        await this.pushCallEvent({
          recipientUserIds: others,
          type: 'group_call_started',
          call,
          conversationType: 'group',
          conversationName: outcome.conversationName ?? 'Group',
          callerId: caller.id,
          callerName: caller.nickname ?? caller.name,
          skipOnlineDevices: true,
          respectDnd: true,
        });
      } else {
        await this.publishBroadcast(
          outcome.memberIds,
          {
            type: 'group_call_updated',
            call_id: call.id,
            conversation_id: call.conversation_id,
            participant_count: call.participant_count,
            participant_ids: call.participant_ids,
          },
          call.conversation_id,
        );
      }
    }

    return {
      call,
      livekit_url: this.livekit.publicUrl,
      token: minted.token,
      expires_in: minted.expiresIn,
      joined_existing: outcome.joinedExisting,
    };
  }

  async acceptCall(input: {
    callId: string;
    userId: string;
    deviceId: string;
  }): Promise<Omit<CallJoinResponse, 'joined_existing'>> {
    this.requireEnabled();

    const user = await this.users.findById(input.userId);
    if (!user) {
      throw new ApiError('not_found', 'User not found');
    }

    const { call, callerId } = await this.calls.acceptCall(input.callId, input.userId);

    const minted = await this.livekit.mintToken({
      roomName: call.room_name,
      userId: user.id,
      displayName: user.nickname ?? user.name,
      metadata: JSON.stringify({
        avatar_url: user.avatar_url,
        device_id: input.deviceId,
      }),
    });

    await this.markUserBusy(user.id, call.id);
    await this.cacheActiveCall(call);

    // Notify caller that callee accepted.
    await this.publishBroadcast(
      [callerId],
      {
        type: 'call_accepted',
        call_id: call.id,
        conversation_id: call.conversation_id,
        accepted_by: user.id,
      },
      call.conversation_id,
    );

    // Stop ringing on callee's other logged-in devices (WS + silent FCM cancel).
    await this.routeToOtherDevices(user.id, input.deviceId, {
      type: 'call_answered_elsewhere',
      call_id: call.id,
      conversation_id: call.conversation_id,
      handled_by_device_id: input.deviceId,
    });
    await this.pushCallEvent({
      recipientUserIds: [user.id],
      excludeDeviceId: input.deviceId,
      type: 'call_cancel',
      call,
      conversationType: 'direct',
      conversationName: '',
      callerId,
      callerName: '',
      reason: 'answered_elsewhere',
      skipOnlineDevices: false,
      respectDnd: false,
    });

    return {
      call,
      livekit_url: this.livekit.publicUrl,
      token: minted.token,
      expires_in: minted.expiresIn,
    };
  }

  async joinGroupCall(input: {
    callId: string;
    userId: string;
    deviceId: string;
  }): Promise<Omit<CallJoinResponse, 'joined_existing'>> {
    this.requireEnabled();

    const user = await this.users.findById(input.userId);
    if (!user) {
      throw new ApiError('not_found', 'User not found');
    }

    const { call, memberIds } = await this.calls.joinGroupCall(
      input.callId,
      input.userId,
      this.config.CALL_MAX_GROUP_PARTICIPANTS,
    );

    const minted = await this.livekit.mintToken({
      roomName: call.room_name,
      userId: user.id,
      displayName: user.nickname ?? user.name,
      metadata: JSON.stringify({
        avatar_url: user.avatar_url,
        device_id: input.deviceId,
      }),
    });

    await this.markUserBusy(user.id, call.id);
    await this.cacheActiveCall(call);

    await this.publishBroadcast(
      memberIds,
      {
        type: 'group_call_updated',
        call_id: call.id,
        conversation_id: call.conversation_id,
        participant_count: call.participant_count,
        participant_ids: call.participant_ids,
      },
      call.conversation_id,
    );

    return {
      call,
      livekit_url: this.livekit.publicUrl,
      token: minted.token,
      expires_in: minted.expiresIn,
    };
  }

  async refreshToken(input: {
    callId: string;
    userId: string;
    deviceId: string;
  }): Promise<{ livekit_url: string; token: string; expires_in: number }> {
    this.requireEnabled();

    const [call, user] = await Promise.all([
      this.calls.requireLiveMemberForTokenRefresh(input.callId, input.userId),
      this.users.findById(input.userId),
    ]);
    if (!user) {
      throw new ApiError('not_found', 'User not found');
    }

    const minted = await this.livekit.mintToken({
      roomName: call.room_name,
      userId: user.id,
      displayName: user.nickname ?? user.name,
      metadata: JSON.stringify({
        avatar_url: user.avatar_url,
        device_id: input.deviceId,
      }),
    });
    await this.markUserBusy(user.id, call.id);

    return {
      livekit_url: this.livekit.publicUrl,
      token: minted.token,
      expires_in: minted.expiresIn,
    };
  }

  async rejectCall(input: {
    callId: string;
    userId: string;
    deviceId: string;
    reason: 'declined' | 'busy';
  }): Promise<void> {
    const outcome = await this.calls.rejectCall(input.callId, input.userId, input.reason);
    if (!outcome.transitioned) return;

    const { call, memberIds } = outcome;
    await this.livekit.deleteRoom(call.room_name);
    await this.clearActiveCall(call.conversation_id, memberIds);

    await this.publishBroadcast(
      [call.initiated_by],
      {
        type: 'call_rejected',
        call_id: call.id,
        conversation_id: call.conversation_id,
        rejected_by: input.userId,
        reason: input.reason,
      },
      call.conversation_id,
    );

    // Dismiss ringing on callee's other devices.
    await this.routeToOtherDevices(input.userId, input.deviceId, {
      type: 'call_ended',
      call_id: call.id,
      conversation_id: call.conversation_id,
      reason: input.reason,
    });
    await this.pushCallEvent({
      recipientUserIds: [input.userId],
      excludeDeviceId: input.deviceId,
      type: 'call_cancel',
      call,
      conversationType: 'direct',
      conversationName: '',
      callerId: call.initiated_by,
      callerName: '',
      reason: input.reason,
      skipOnlineDevices: false,
      respectDnd: false,
    });
  }

  async cancelCall(input: { callId: string; userId: string }): Promise<void> {
    const outcome = await this.calls.cancelCall(input.callId, input.userId);
    if (!outcome.transitioned) return;

    const { call, memberIds } = outcome;
    await this.livekit.deleteRoom(call.room_name);
    await this.clearActiveCall(call.conversation_id, memberIds);

    const others = memberIds.filter((id) => id !== input.userId);
    await this.publishBroadcast(
      others,
      {
        type: 'call_cancelled',
        call_id: call.id,
        conversation_id: call.conversation_id,
        cancelled_by: input.userId,
      },
      call.conversation_id,
    );

    // Dismiss ringing notification on background/terminated callee devices.
    await this.pushCallEvent({
      recipientUserIds: others,
      type: 'call_cancel',
      call,
      conversationType: 'direct',
      conversationName: '',
      callerId: input.userId,
      callerName: '',
      reason: 'cancelled',
      skipOnlineDevices: false,
      respectDnd: false,
    });
  }

  async leaveCall(input: { callId: string; userId: string }): Promise<void> {
    const outcome = await this.calls.leaveCall(input.callId, input.userId);
    const { call, ended, memberIds } = outcome;

    await this.clearUserBusy(input.userId);

    if (ended) {
      await this.livekit.deleteRoom(call.room_name);
      await this.clearActiveCall(call.conversation_id, memberIds);

      const others = memberIds.filter((id) => id !== input.userId);
      await this.publishBroadcast(
        others,
        {
          type: 'call_ended',
          call_id: call.id,
          conversation_id: call.conversation_id,
          reason: 'hangup',
        },
        call.conversation_id,
      );
      await this.pushCallEvent({
        recipientUserIds: others,
        type: 'call_ended',
        call,
        conversationType: call.type === 'group' ? 'group' : 'direct',
        conversationName: '',
        callerId: call.initiated_by,
        callerName: '',
        reason: 'hangup',
        skipOnlineDevices: false,
        respectDnd: false,
      });
      return;
    }

    if (call.type === 'group') {
      await this.cacheActiveCall(call);
      await this.publishBroadcast(
        memberIds,
        {
          type: 'group_call_updated',
          call_id: call.id,
          conversation_id: call.conversation_id,
          participant_count: call.participant_count,
          participant_ids: call.participant_ids,
        },
        call.conversation_id,
      );
    }
  }

  async getActiveCallForConversation(
    conversationId: string,
    userId: string,
  ): Promise<CallSummary | null> {
    return this.calls.getActiveCallForConversation(conversationId, userId);
  }

  async listActiveCallsForUser(userId: string): Promise<CallSummary[]> {
    return this.calls.listActiveCallsForUser(userId);
  }

  async handleWebhook(rawBody: string, authHeader: string): Promise<void> {
    const event = await this.livekit.verifyWebhook(rawBody, authHeader);
    const roomName = event.room?.name;
    if (!roomName) return;

    this.logger.info(
      { event: event.event, room_name: roomName, identity: event.participant?.identity },
      'LiveKit webhook received',
    );

    switch (event.event) {
      case 'room_started': {
        // Nothing extra needed beyond logging; room is already tracked in Postgres.
        return;
      }

      case 'participant_joined': {
        const userId = event.participant?.identity;
        if (!userId) return;
        const result = await this.calls.markParticipantJoinedByRoom(roomName, userId);
        if (!result) return;
        await this.markUserBusy(userId, result.call.id);
        await this.cacheActiveCall(result.call);
        if (result.call.type === 'group') {
          await this.publishBroadcast(
            result.memberIds,
            {
              type: 'group_call_updated',
              call_id: result.call.id,
              conversation_id: result.call.conversation_id,
              participant_count: result.call.participant_count,
              participant_ids: result.call.participant_ids,
            },
            result.call.conversation_id,
          );
        }
        return;
      }

      case 'participant_left': {
        const userId = event.participant?.identity;
        if (!userId) return;
        const result = await this.calls.markParticipantLeftByRoom(roomName, userId);
        if (!result) return;
        await this.clearUserBusy(userId);
        await this.cacheActiveCall(result.call);
        if (result.call.type === 'group') {
          await this.publishBroadcast(
            result.memberIds,
            {
              type: 'group_call_updated',
              call_id: result.call.id,
              conversation_id: result.call.conversation_id,
              participant_count: result.call.participant_count,
              participant_ids: result.call.participant_ids,
            },
            result.call.conversation_id,
          );
        }
        return;
      }

      case 'room_finished': {
        await this.finalizeFinishedRoom(roomName, 'room_finished');
        return;
      }

      default:
        return;
    }
  }

  /** Periodic sweeper for unanswered 1:1 calls past `ring_expires_at`. */
  async sweepExpiredRinging(): Promise<number> {
    const expired = await this.calls.sweepExpiredRingingCalls();
    for (const item of expired) {
      const { call, memberIds, participantIds } = item;
      await this.livekit.deleteRoom(call.room_name);
      await this.clearActiveCall(call.conversation_id, [
        ...new Set([...memberIds, ...participantIds]),
      ]);

      await this.publishBroadcast(
        memberIds,
        {
          type: 'call_ended',
          call_id: call.id,
          conversation_id: call.conversation_id,
          reason: 'missed',
        },
        call.conversation_id,
      );

      const callees = memberIds.filter((id) => id !== call.initiated_by);
      await this.pushCallEvent({
        recipientUserIds: callees,
        type: 'call_cancel',
        call,
        conversationType: 'direct',
        conversationName: '',
        callerId: call.initiated_by,
        callerName: '',
        reason: 'missed',
        skipOnlineDevices: false,
        respectDnd: false,
      });
    }
    return expired.length;
  }

  /** Reconciles active DB calls whose LiveKit room no longer exists (missed webhook). */
  async reconcileGhostRooms(): Promise<number> {
    if (!this.livekit.enabled) return 0;
    const stale = await this.calls.listStaleActiveCalls(120);
    if (stale.length === 0) return 0;

    let liveRoomNames: Set<string>;
    try {
      const names = await this.livekit.listRooms(stale.map((c) => c.room_name));
      liveRoomNames = new Set(names);
    } catch (error) {
      this.logger.warn({ err: error }, 'LiveKit listRooms failed during ghost-room sweep');
      return 0;
    }

    let cleaned = 0;
    for (const call of stale) {
      if (!liveRoomNames.has(call.room_name)) {
        await this.finalizeFinishedRoom(call.room_name, 'ghost_reconciled');
        cleaned += 1;
      }
    }
    return cleaned;
  }

  private async finalizeFinishedRoom(roomName: string, reason: string): Promise<void> {
    const result = await this.calls.markRoomFinished(roomName, reason);
    if (!result) return;

    await this.clearActiveCall(result.call.conversation_id, [
      ...new Set([...result.memberIds, ...result.clearedUserIds]),
    ]);
    if (!result.transitioned) return;

    if (result.call.type === 'group') {
      await this.publishBroadcast(
        result.memberIds,
        {
          type: 'group_call_ended',
          call_id: result.call.id,
          conversation_id: result.call.conversation_id,
          reason,
        },
        result.call.conversation_id,
      );
      return;
    }

    await this.publishBroadcast(
      result.memberIds,
      {
        type: 'call_ended',
        call_id: result.call.id,
        conversation_id: result.call.conversation_id,
        reason: result.wasRinging ? 'missed' : reason,
      },
      result.call.conversation_id,
    );

    if (result.wasRinging) {
      const callees = result.memberIds.filter((id) => id !== result.call.initiated_by);
      await this.pushCallEvent({
        recipientUserIds: callees,
        type: 'call_cancel',
        call: result.call,
        conversationType: 'direct',
        conversationName: '',
        callerId: result.call.initiated_by,
        callerName: '',
        reason: 'missed',
        skipOnlineDevices: false,
        respectDnd: false,
      });
    }
  }

  private requireEnabled(): void {
    if (!this.livekit.enabled) {
      throw new ApiError('calls_unavailable', 'Voice and video calling is not configured');
    }
  }

  private async markUserBusy(userId: string, callId: string): Promise<void> {
    await this.redis.set(redisKeys.callUser(userId), callId, 'EX', USER_CALL_TTL_SECONDS);
  }

  private async clearUserBusy(userId: string): Promise<void> {
    await this.redis.del(redisKeys.callUser(userId));
  }

  private async cacheActiveCall(call: CallSummary): Promise<void> {
    await this.redis.set(
      redisKeys.activeCall(call.conversation_id),
      JSON.stringify({
        call_id: call.id,
        type: call.type,
        media_type: call.media_type,
        status: call.status,
        participant_count: call.participant_count,
      }),
      'EX',
      ACTIVE_CALL_CACHE_TTL_SECONDS,
    );
  }

  private async clearActiveCall(conversationId: string, userIds: string[]): Promise<void> {
    const keys = [
      redisKeys.activeCall(conversationId),
      ...userIds.map((userId) => redisKeys.callUser(userId)),
    ];
    if (keys.length > 0) {
      await this.redis.del(...keys);
    }
  }

  private async publishBroadcast(
    userIds: string[],
    frame: Record<string, unknown>,
    conversationId: string,
  ): Promise<void> {
    const unique = [...new Set(userIds)];
    if (unique.length === 0) return;
    await this.broker.publishBroadcast({ user_ids: unique, frame }, `c:${conversationId}`);
  }

  private async routeToOtherDevices(
    userId: string,
    excludeDeviceId: string,
    frame: Record<string, unknown>,
  ): Promise<void> {
    const devices = await this.connections.liveDevices(userId);
    const nodes = new Set<string>();
    for (const deviceId of devices) {
      if (deviceId === excludeDeviceId) continue;
      const node = await this.redis.get(redisKeys.connection(userId, deviceId));
      if (node) nodes.add(node);
    }
    for (const node of nodes) {
      await this.broker.publishToNode(
        node,
        { userId, frame, excludeDevice: excludeDeviceId },
        `u:${userId}`,
      );
    }
  }

  private async pushCallEvent(input: {
    recipientUserIds: string[];
    excludeDeviceId?: string;
    type: CallPushEventType;
    call: CallSummary;
    conversationType: 'direct' | 'group';
    conversationName: string;
    callerId: string;
    callerName: string;
    expiresAtMs?: number;
    reason?: string;
    skipOnlineDevices: boolean;
    respectDnd: boolean;
  }): Promise<void> {
    if (!this.notifications.enabled || input.recipientUserIds.length === 0) return;

    for (const recipientId of [...new Set(input.recipientUserIds)]) {
      if (input.respectDnd) {
        const recipient = await this.users.findById(recipientId);
        if (recipient?.status === 'dnd') continue;
      }

      const [tokens, liveDevices] = await Promise.all([
        this.devices.tokensForUser(recipientId),
        input.skipOnlineDevices
          ? this.connections.liveDevices(recipientId)
          : Promise.resolve<string[]>([]),
      ]);
      const liveSet = new Set(liveDevices);

      const targetFids = tokens
        .filter((row) => {
          if (input.excludeDeviceId && row.device_id === input.excludeDeviceId) return false;
          if (input.skipOnlineDevices && liveSet.has(row.device_id)) return false;
          return true;
        })
        .map((row) => row.fcm_token);

      if (targetFids.length === 0) continue;

      const stale = await this.notifications.notifyCallEvent(targetFids, {
        type: input.type,
        callId: input.call.id,
        conversationId: input.call.conversation_id,
        conversationType: input.conversationType,
        conversationName: input.conversationName,
        callType: input.call.type,
        mediaType: input.call.media_type,
        callerId: input.callerId,
        callerName: input.callerName,
        recipientUserId: recipientId,
        expiresAtMs: input.expiresAtMs,
        reason: input.reason,
      });

      if (stale.length > 0) {
        await this.devices.removeStale(stale);
      }
    }
  }
}
