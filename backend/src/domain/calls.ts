import { randomUUID } from 'node:crypto';

import { ApiError } from '../lib/errors.js';
import type { Db, PoolClient } from '../lib/db.js';

export type CallType = '1on1' | 'group';
export type CallMediaType = 'voice' | 'video';
export type CallStatus =
  | 'ringing'
  | 'active'
  | 'ended'
  | 'missed'
  | 'rejected'
  | 'cancelled'
  | 'busy'
  | 'failed';
export type CallParticipantState =
  | 'ringing'
  | 'joining'
  | 'joined'
  | 'left'
  | 'rejected'
  | 'missed';

export type CallRow = {
  id: string;
  conversation_id: string;
  room_name: string;
  type: CallType;
  media_type: CallMediaType;
  initiated_by: string;
  status: CallStatus;
  ring_expires_at: Date | null;
  started_at: Date;
  answered_at: Date | null;
  ended_at: Date | null;
  end_reason: string | null;
};

export type CallSummary = {
  id: string;
  conversation_id: string;
  room_name: string;
  type: CallType;
  media_type: CallMediaType;
  initiated_by: string;
  status: CallStatus;
  ring_expires_at: Date | null;
  started_at: Date;
  answered_at: Date | null;
  ended_at: Date | null;
  end_reason: string | null;
  participant_count: number;
  participant_ids: string[];
};

export type StartCallOutcome = {
  call: CallSummary;
  conversationType: 'direct' | 'group';
  conversationName: string | null;
  joinedExisting: boolean;
  autoAcceptedCollision: boolean;
  peerId: string | null;
  memberIds: string[];
};

export type AcceptCallOutcome = {
  call: CallSummary;
  callerId: string;
};

export type LeaveCallOutcome = {
  call: CallSummary;
  ended: boolean;
  memberIds: string[];
};

export type TerminalCallOutcome = {
  call: CallSummary;
  transitioned: boolean;
  memberIds: string[];
};

const CALL_COLUMNS = `id, conversation_id, room_name, type, media_type, initiated_by,
                      status, ring_expires_at, started_at, answered_at, ended_at, end_reason`;

export class CallRepository {
  constructor(private readonly db: Db) {}

  async findById(callId: string): Promise<CallRow | null> {
    const { rows } = await this.db.query<CallRow>(
      `SELECT ${CALL_COLUMNS} FROM calls WHERE id = $1`,
      [callId],
    );
    return rows[0] ?? null;
  }

  async findByRoomName(roomName: string): Promise<CallRow | null> {
    const { rows } = await this.db.query<CallRow>(
      `SELECT ${CALL_COLUMNS} FROM calls WHERE room_name = $1`,
      [roomName],
    );
    return rows[0] ?? null;
  }

  /**
   * Starts a 1:1 call or starts/atomically-joins a group call.
   *
   * Locks the `conversations` row (`FOR UPDATE`) so simultaneous taps on a
   * group call or simultaneous 1:1 calls between the same pair always converge
   * onto a single `calls` row (backed by `calls_one_live_per_conversation_idx`).
   */
  async startOrJoinConversationCall(input: {
    conversationId: string;
    callerId: string;
    mediaType: CallMediaType;
    ringTimeoutSeconds: number;
    maxGroupParticipants: number;
  }): Promise<StartCallOutcome> {
    return this.transaction(async (client) => {
      const { rows: convRows } = await client.query<{
        id: string;
        type: 'direct' | 'group';
        name: string | null;
      }>(`SELECT id, type, name FROM conversations WHERE id = $1 FOR UPDATE`, [
        input.conversationId,
      ]);
      const conversation = convRows[0];
      if (!conversation) {
        throw new ApiError('conversation_not_found', 'Conversation not found');
      }

      const { rows: memberRows } = await client.query<{ user_id: string }>(
        `SELECT user_id FROM conversation_members WHERE conversation_id = $1`,
        [input.conversationId],
      );
      const memberIds = memberRows.map((row) => row.user_id);
      if (!memberIds.includes(input.callerId)) {
        throw new ApiError('not_a_member', 'You are not a member of this conversation');
      }

      // Reap any expired 1:1 ringing call on this conversation before checking for live calls.
      await client.query(
        `UPDATE calls
            SET status = 'missed', ended_at = NOW(), end_reason = 'timeout'
          WHERE conversation_id = $1
            AND type = '1on1'
            AND status = 'ringing'
            AND ring_expires_at <= NOW()`,
        [input.conversationId],
      );

      const { rows: liveRows } = await client.query<CallRow>(
        `SELECT ${CALL_COLUMNS}
           FROM calls
          WHERE conversation_id = $1
            AND status IN ('ringing', 'active')
          LIMIT 1`,
        [input.conversationId],
      );
      const existing = liveRows[0];

      if (conversation.type === 'direct') {
        const peerId = memberIds.find((id) => id !== input.callerId) ?? null;
        if (!peerId) {
          throw new ApiError('validation_error', 'Direct conversation requires another member');
        }

        if (existing) {
          // Simultaneous 1:1 call collision: peer is already ringing us -> converge & auto-accept.
          if (existing.status === 'ringing' && existing.initiated_by === peerId) {
            const { rows: acceptedRows } = await client.query<CallRow>(
              `UPDATE calls
                  SET status = 'active', answered_at = NOW()
                WHERE id = $1
                RETURNING ${CALL_COLUMNS}`,
              [existing.id],
            );
            await this.upsertParticipant(client, existing.id, input.callerId, 'joining');
            const summary = await this.toSummary(client, acceptedRows[0]!);
            return {
              call: summary,
              conversationType: 'direct',
              conversationName: conversation.name,
              joinedExisting: true,
              autoAcceptedCollision: true,
              peerId,
              memberIds,
            };
          }

          // Caller already started or is already in this call -> idempotent return.
          if (existing.initiated_by === input.callerId || existing.status === 'active') {
            await this.upsertParticipant(client, existing.id, input.callerId, 'joining');
            const summary = await this.toSummary(client, existing);
            return {
              call: summary,
              conversationType: 'direct',
              conversationName: conversation.name,
              joinedExisting: true,
              autoAcceptedCollision: false,
              peerId,
              memberIds,
            };
          }
        }

        // Check if caller is already in another live call.
        if (await this.isUserInAnotherLiveCall(client, input.callerId, null)) {
          throw new ApiError('conflict', 'You are already in another call');
        }
        // Check if callee is already busy in another live call.
        if (await this.isUserInAnotherLiveCall(client, peerId, null)) {
          throw new ApiError('callee_busy', 'Recipient is busy on another call');
        }

        const callId = randomUUID();
        const roomName = `call_${callId}`;
        const { rows: insertedRows } = await client.query<CallRow>(
          `INSERT INTO calls (
             id, conversation_id, room_name, type, media_type, initiated_by, status, ring_expires_at
           )
           VALUES ($1, $2, $3, '1on1', $4, $5, 'ringing', NOW() + ($6 * INTERVAL '1 second'))
           RETURNING ${CALL_COLUMNS}`,
          [
            callId,
            input.conversationId,
            roomName,
            input.mediaType,
            input.callerId,
            input.ringTimeoutSeconds,
          ],
        );
        const created = insertedRows[0]!;
        await client.query(
          `INSERT INTO call_participants (call_id, user_id, state)
           VALUES ($1, $2, 'joining'), ($1, $3, 'ringing')`,
          [created.id, input.callerId, peerId],
        );

        const summary = await this.toSummary(client, created);
        return {
          call: summary,
          conversationType: 'direct',
          conversationName: conversation.name,
          joinedExisting: false,
          autoAcceptedCollision: false,
          peerId,
          memberIds,
        };
      }

      // ---- Group call ----
      if (existing) {
        const activeIds = await this.activeParticipantIds(client, existing.id);
        if (!activeIds.includes(input.callerId) && activeIds.length >= input.maxGroupParticipants) {
          throw new ApiError(
            'call_full',
            `Group calls are limited to ${input.maxGroupParticipants} participants`,
          );
        }
        await this.upsertParticipant(client, existing.id, input.callerId, 'joining');
        const summary = await this.toSummary(client, existing);
        return {
          call: summary,
          conversationType: 'group',
          conversationName: conversation.name,
          joinedExisting: true,
          autoAcceptedCollision: false,
          peerId: null,
          memberIds,
        };
      }

      const callId = randomUUID();
      const roomName = `call_${callId}`;
      const { rows: insertedRows } = await client.query<CallRow>(
        `INSERT INTO calls (
           id, conversation_id, room_name, type, media_type, initiated_by, status, ring_expires_at
         )
         VALUES ($1, $2, $3, 'group', $4, $5, 'active', NULL)
         RETURNING ${CALL_COLUMNS}`,
        [callId, input.conversationId, roomName, input.mediaType, input.callerId],
      );
      const created = insertedRows[0]!;
      await this.upsertParticipant(client, created.id, input.callerId, 'joining');

      const summary = await this.toSummary(client, created);
      return {
        call: summary,
        conversationType: 'group',
        conversationName: conversation.name,
        joinedExisting: false,
        autoAcceptedCollision: false,
        peerId: null,
        memberIds,
      };
    });
  }

  async acceptCall(callId: string, userId: string): Promise<AcceptCallOutcome> {
    return this.transaction(async (client) => {
      const call = await this.lockCall(client, callId);
      await this.requireMembership(client, call.conversation_id, userId);

      if (call.type !== '1on1') {
        throw new ApiError('conflict', 'Use /join for group calls');
      }
      if (call.initiated_by === userId) {
        throw new ApiError('forbidden', 'Caller cannot accept their own outgoing call');
      }
      if (call.status !== 'ringing') {
        throw new ApiError('call_already_ended', 'Call is no longer ringing');
      }
      if (call.ring_expires_at && call.ring_expires_at.getTime() <= Date.now()) {
        await client.query(
          `UPDATE calls SET status = 'missed', ended_at = NOW(), end_reason = 'timeout' WHERE id = $1`,
          [call.id],
        );
        await client.query(
          `UPDATE call_participants SET state = 'missed' WHERE call_id = $1 AND state = 'ringing'`,
          [call.id],
        );
        throw new ApiError('call_already_ended', 'Call has timed out');
      }

      const { rows } = await client.query<CallRow>(
        `UPDATE calls
            SET status = 'active', answered_at = NOW()
          WHERE id = $1
          RETURNING ${CALL_COLUMNS}`,
        [call.id],
      );
      await this.upsertParticipant(client, call.id, userId, 'joining');

      const summary = await this.toSummary(client, rows[0]!);
      return { call: summary, callerId: call.initiated_by };
    });
  }

  async joinGroupCall(
    callId: string,
    userId: string,
    maxParticipants: number,
  ): Promise<{ call: CallSummary; memberIds: string[] }> {
    return this.transaction(async (client) => {
      const call = await this.lockCall(client, callId);
      await this.requireMembership(client, call.conversation_id, userId);

      if (call.type !== 'group') {
        throw new ApiError('conflict', 'Use /accept for 1-on-1 calls');
      }
      if (call.status !== 'active') {
        throw new ApiError('call_already_ended', 'Group call has ended');
      }

      const activeIds = await this.activeParticipantIds(client, call.id);
      if (!activeIds.includes(userId) && activeIds.length >= maxParticipants) {
        throw new ApiError('call_full', `Group calls are limited to ${maxParticipants} participants`);
      }

      await this.upsertParticipant(client, call.id, userId, 'joining');
      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      const summary = await this.toSummary(client, call);
      return { call: summary, memberIds };
    });
  }

  async requireLiveMemberForTokenRefresh(callId: string, userId: string): Promise<CallRow> {
    const call = await this.findById(callId);
    if (!call) {
      throw new ApiError('call_not_found', 'Call not found');
    }
    if (call.status !== 'ringing' && call.status !== 'active') {
      throw new ApiError('call_already_ended', 'Call has already ended');
    }
    await this.requireMembership(this.db, call.conversation_id, userId);
    return call;
  }

  async rejectCall(
    callId: string,
    userId: string,
    reason: 'declined' | 'busy',
  ): Promise<TerminalCallOutcome> {
    return this.transaction(async (client) => {
      const call = await this.lockCall(client, callId);
      await this.requireMembership(client, call.conversation_id, userId);

      if (call.type !== '1on1') {
        throw new ApiError('conflict', 'Group calls cannot be rejected');
      }
      if (call.initiated_by === userId) {
        throw new ApiError('forbidden', 'Use /cancel to abort your own outgoing call');
      }

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      if (call.status !== 'ringing') {
        return { call: await this.toSummary(client, call), transitioned: false, memberIds };
      }

      const nextStatus: CallStatus = reason === 'busy' ? 'busy' : 'rejected';
      const { rows } = await client.query<CallRow>(
        `UPDATE calls
            SET status = $2, ended_at = NOW(), end_reason = $3
          WHERE id = $1
          RETURNING ${CALL_COLUMNS}`,
        [call.id, nextStatus, reason],
      );
      await client.query(
        `UPDATE call_participants
            SET state = 'rejected', left_at = NOW()
          WHERE call_id = $1 AND user_id = $2`,
        [call.id, userId],
      );
      await client.query(
        `UPDATE call_participants
            SET state = 'left', left_at = NOW()
          WHERE call_id = $1 AND user_id <> $2 AND state IN ('joining', 'joined')`,
        [call.id, userId],
      );

      return { call: await this.toSummary(client, rows[0]!), transitioned: true, memberIds };
    });
  }

  async cancelCall(callId: string, userId: string): Promise<TerminalCallOutcome> {
    return this.transaction(async (client) => {
      const call = await this.lockCall(client, callId);
      await this.requireMembership(client, call.conversation_id, userId);

      if (call.initiated_by !== userId) {
        throw new ApiError('forbidden', 'Only the caller can cancel a ringing call');
      }

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      if (call.status !== 'ringing') {
        return { call: await this.toSummary(client, call), transitioned: false, memberIds };
      }

      const { rows } = await client.query<CallRow>(
        `UPDATE calls
            SET status = 'cancelled', ended_at = NOW(), end_reason = 'cancelled'
          WHERE id = $1
          RETURNING ${CALL_COLUMNS}`,
        [call.id],
      );
      await client.query(
        `UPDATE call_participants
            SET state = CASE WHEN state = 'ringing' THEN 'missed' ELSE 'left' END,
                left_at = NOW()
          WHERE call_id = $1 AND state IN ('ringing', 'joining', 'joined')`,
        [call.id],
      );

      return { call: await this.toSummary(client, rows[0]!), transitioned: true, memberIds };
    });
  }

  async leaveCall(callId: string, userId: string): Promise<LeaveCallOutcome> {
    return this.transaction(async (client) => {
      const call = await this.lockCall(client, callId);
      const isMember = await this.isMemberIn(client, call.conversation_id, userId);
      const { rows: partRows } = await client.query(
        `SELECT 1 FROM call_participants WHERE call_id = $1 AND user_id = $2`,
        [call.id, userId],
      );
      if (!isMember && partRows.length === 0) {
        throw new ApiError('not_a_member', 'You are not a member of this conversation');
      }

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      await client.query(
        `UPDATE call_participants
            SET state = 'left', left_at = NOW()
          WHERE call_id = $1 AND user_id = $2 AND state IN ('ringing', 'joining', 'joined')`,
        [call.id, userId],
      );

      if (call.type === '1on1' && (call.status === 'ringing' || call.status === 'active')) {
        const nextStatus: CallStatus = call.status === 'ringing' ? 'cancelled' : 'ended';
        const { rows } = await client.query<CallRow>(
          `UPDATE calls
              SET status = $2, ended_at = NOW(), end_reason = 'hangup'
            WHERE id = $1
            RETURNING ${CALL_COLUMNS}`,
          [call.id, nextStatus],
        );
        await client.query(
          `UPDATE call_participants
              SET state = 'left', left_at = NOW()
            WHERE call_id = $1 AND state IN ('ringing', 'joining', 'joined')`,
          [call.id],
        );
        return { call: await this.toSummary(client, rows[0]!), ended: true, memberIds };
      }

      // Group call: one member leaving does NOT end the call. LiveKit's
      // `room_finished` webhook closes the call after the last member leaves.
      return { call: await this.toSummary(client, call), ended: false, memberIds };
    });
  }

  async markParticipantJoinedByRoom(
    roomName: string,
    userId: string,
  ): Promise<{ call: CallSummary; memberIds: string[] } | null> {
    return this.transaction(async (client) => {
      const { rows } = await client.query<CallRow>(
        `SELECT ${CALL_COLUMNS} FROM calls WHERE room_name = $1 FOR UPDATE`,
        [roomName],
      );
      const call = rows[0];
      if (!call) return null;

      await client.query(
        `INSERT INTO call_participants (call_id, user_id, state, joined_at, left_at)
         VALUES ($1, $2, 'joined', NOW(), NULL)
         ON CONFLICT (call_id, user_id)
         DO UPDATE SET state = 'joined',
                       joined_at = COALESCE(call_participants.joined_at, NOW()),
                       left_at = NULL`,
        [call.id, userId],
      );

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      return { call: await this.toSummary(client, call), memberIds };
    });
  }

  async markParticipantLeftByRoom(
    roomName: string,
    userId: string,
  ): Promise<{ call: CallSummary; memberIds: string[] } | null> {
    return this.transaction(async (client) => {
      const { rows } = await client.query<CallRow>(
        `SELECT ${CALL_COLUMNS} FROM calls WHERE room_name = $1 FOR UPDATE`,
        [roomName],
      );
      const call = rows[0];
      if (!call) return null;

      await client.query(
        `UPDATE call_participants
            SET state = 'left', left_at = NOW()
          WHERE call_id = $1 AND user_id = $2`,
        [call.id, userId],
      );

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      return { call: await this.toSummary(client, call), memberIds };
    });
  }

  async markRoomFinished(
    roomName: string,
    reason = 'room_finished',
  ): Promise<{ call: CallSummary; wasRinging: boolean; transitioned: boolean; memberIds: string[]; clearedUserIds: string[] } | null> {
    return this.transaction(async (client) => {
      const { rows } = await client.query<CallRow>(
        `SELECT ${CALL_COLUMNS} FROM calls WHERE room_name = $1 FOR UPDATE`,
        [roomName],
      );
      const call = rows[0];
      if (!call) return null;

      const memberIds = await this.memberIdsIn(client, call.conversation_id);
      const { rows: activePartRows } = await client.query<{ user_id: string }>(
        `SELECT user_id FROM call_participants WHERE call_id = $1 AND state IN ('ringing', 'joining', 'joined')`,
        [call.id],
      );
      const clearedUserIds = activePartRows.map((row) => row.user_id);

      if (call.status !== 'ringing' && call.status !== 'active') {
        return {
          call: await this.toSummary(client, call),
          wasRinging: false,
          transitioned: false,
          memberIds,
          clearedUserIds,
        };
      }

      const wasRinging = call.status === 'ringing';
      const nextStatus: CallStatus = wasRinging ? 'missed' : 'ended';
      const { rows: updatedRows } = await client.query<CallRow>(
        `UPDATE calls
            SET status = $2, ended_at = NOW(), end_reason = $3
          WHERE id = $1
          RETURNING ${CALL_COLUMNS}`,
        [call.id, nextStatus, reason],
      );
      await client.query(
        `UPDATE call_participants
            SET state = CASE WHEN state = 'ringing' THEN 'missed' ELSE 'left' END,
                left_at = NOW()
          WHERE call_id = $1 AND state IN ('ringing', 'joining', 'joined')`,
        [call.id],
      );

      return {
        call: await this.toSummary(client, updatedRows[0]!),
        wasRinging,
        transitioned: true,
        memberIds,
        clearedUserIds,
      };
    });
  }

  async getActiveCallForConversation(
    conversationId: string,
    userId: string,
  ): Promise<CallSummary | null> {
    await this.requireMembership(this.db, conversationId, userId);
    const { rows } = await this.db.query<CallRow>(
      `SELECT ${CALL_COLUMNS}
         FROM calls
        WHERE conversation_id = $1
          AND status IN ('ringing', 'active')
        LIMIT 1`,
      [conversationId],
    );
    const row = rows[0];
    if (!row) return null;
    return this.toSummary(this.db, row);
  }

  async listActiveCallsForUser(userId: string): Promise<CallSummary[]> {
    const { rows } = await this.db.query<CallRow>(
      `SELECT c.id, c.conversation_id, c.room_name, c.type, c.media_type, c.initiated_by,
              c.status, c.ring_expires_at, c.started_at, c.answered_at, c.ended_at, c.end_reason
         FROM calls c
         JOIN conversation_members cm
           ON cm.conversation_id = c.conversation_id AND cm.user_id = $1
        WHERE c.status IN ('ringing', 'active')
        ORDER BY c.started_at DESC`,
      [userId],
    );
    return Promise.all(rows.map((row) => this.toSummary(this.db, row)));
  }

  /**
   * Atomically transitions expired 1:1 ringing calls to `missed`.
   * Safe across multiple API replicas without distributed locks.
   */
  async sweepExpiredRingingCalls(): Promise<
    Array<{ call: CallSummary; memberIds: string[]; participantIds: string[] }>
  > {
    return this.transaction(async (client) => {
      const { rows } = await client.query<CallRow>(
        `UPDATE calls
            SET status = 'missed', ended_at = NOW(), end_reason = 'timeout'
          WHERE type = '1on1'
            AND status = 'ringing'
            AND ring_expires_at <= NOW()
          RETURNING ${CALL_COLUMNS}`,
      );
      if (rows.length === 0) return [];

      const results: Array<{ call: CallSummary; memberIds: string[]; participantIds: string[] }> = [];
      for (const call of rows) {
        const { rows: partRows } = await client.query<{ user_id: string }>(
          `UPDATE call_participants
              SET state = CASE WHEN state = 'ringing' THEN 'missed' ELSE 'left' END,
                  left_at = NOW()
            WHERE call_id = $1 AND state IN ('ringing', 'joining', 'joined')
            RETURNING user_id`,
          [call.id],
        );
        const memberIds = await this.memberIdsIn(client, call.conversation_id);
        results.push({
          call: await this.toSummary(client, call),
          memberIds,
          participantIds: partRows.map((row) => row.user_id),
        });
      }
      return results;
    });
  }

  /** Active calls older than `olderThanSeconds` for ghost-room reconciliation. */
  async listStaleActiveCalls(olderThanSeconds = 120): Promise<CallRow[]> {
    const { rows } = await this.db.query<CallRow>(
      `SELECT ${CALL_COLUMNS}
         FROM calls
        WHERE status = 'active'
          AND started_at <= NOW() - ($1 * INTERVAL '1 second')`,
      [olderThanSeconds],
    );
    return rows;
  }

  private async lockCall(client: Pick<Db, 'query'>, callId: string): Promise<CallRow> {
    const { rows } = await client.query<CallRow>(
      `SELECT ${CALL_COLUMNS} FROM calls WHERE id = $1 FOR UPDATE`,
      [callId],
    );
    if (!rows[0]) {
      throw new ApiError('call_not_found', 'Call not found');
    }
    return rows[0];
  }

  private async isMemberIn(
    client: Pick<Db, 'query'>,
    conversationId: string,
    userId: string,
  ): Promise<boolean> {
    const { rows } = await client.query(
      `SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, userId],
    );
    return rows.length > 0;
  }

  private async requireMembership(
    client: Pick<Db, 'query'>,
    conversationId: string,
    userId: string,
  ): Promise<void> {
    const isMember = await this.isMemberIn(client, conversationId, userId);
    if (!isMember) {
      throw new ApiError('not_a_member', 'You are not a member of this conversation');
    }
  }

  private async memberIdsIn(client: Pick<Db, 'query'>, conversationId: string): Promise<string[]> {
    const { rows } = await client.query<{ user_id: string }>(
      `SELECT user_id FROM conversation_members WHERE conversation_id = $1`,
      [conversationId],
    );
    return rows.map((row) => row.user_id);
  }

  private async isUserInAnotherLiveCall(
    client: Pick<Db, 'query'>,
    userId: string,
    excludeCallId: string | null,
  ): Promise<boolean> {
    const { rows } = await client.query(
      `SELECT 1
         FROM call_participants cp
         JOIN calls c ON c.id = cp.call_id
        WHERE cp.user_id = $1
          AND cp.state IN ('ringing', 'joining', 'joined')
          AND c.status IN ('ringing', 'active')
          AND ($2::uuid IS NULL OR c.id <> $2)
        LIMIT 1`,
      [userId, excludeCallId],
    );
    return rows.length > 0;
  }

  private async upsertParticipant(
    client: Pick<Db, 'query'>,
    callId: string,
    userId: string,
    state: CallParticipantState,
  ): Promise<void> {
    await client.query(
      `INSERT INTO call_participants (call_id, user_id, state, left_at)
       VALUES ($1, $2, $3, NULL)
       ON CONFLICT (call_id, user_id)
       DO UPDATE SET state = EXCLUDED.state, left_at = NULL`,
      [callId, userId, state],
    );
  }

  private async activeParticipantIds(
    client: Pick<Db, 'query'>,
    callId: string,
  ): Promise<string[]> {
    const { rows } = await client.query<{ user_id: string }>(
      `SELECT user_id
         FROM call_participants
        WHERE call_id = $1 AND state IN ('joining', 'joined')
        ORDER BY joined_at ASC NULLS LAST, user_id ASC`,
      [callId],
    );
    return rows.map((row) => row.user_id);
  }

  private async toSummary(client: Pick<Db, 'query'>, row: CallRow): Promise<CallSummary> {
    const participantIds = await this.activeParticipantIds(client, row.id);
    return {
      ...row,
      participant_count: participantIds.length,
      participant_ids: participantIds,
    };
  }

  private async transaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.db.connect();
    try {
      await client.query('BEGIN');
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}
