import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/call_models.dart';
import '../../core/models/models.dart';
import '../../core/notifications/notification_policy.dart';
import '../../core/providers.dart';
import 'call_foreground_service.dart';
import 'call_permissions.dart';
import 'livekit_media_service.dart';

final callPermissionServiceProvider = Provider<CallPermissionService>(
  (ref) => const CallPermissionService(),
);

final callForegroundServiceProvider = Provider<CallForegroundServiceBridge>((ref) {
  final bridge = CallForegroundServiceBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Account-scoped LiveKit media engine. Disposed and rebuilt whenever
/// `accountScopeProvider` changes (logout / account switch).
final livekitMediaServiceProvider = Provider<CallMediaEngine>((ref) {
  ref.watch(accountScopeProvider);
  final service = LiveKitMediaService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Map of `conversationId -> ActiveCallSummary` for ongoing group calls across
/// the user's chats. Powers the `ChatScreen` Join banner and `ConversationsScreen`
/// "In call" pill.
class ActiveGroupCallsNotifier extends Notifier<Map<String, ActiveCallSummary>> {
  @override
  Map<String, ActiveCallSummary> build() {
    ref.watch(accountScopeProvider);
    return const {};
  }

  void setAll(List<ActiveCallSummary> calls) {
    final next = <String, ActiveCallSummary>{};
    for (final call in calls) {
      if (call.isGroup && (call.status == 'active' || call.status == 'ringing')) {
        next[call.conversationId] = call;
      }
    }
    state = Map<String, ActiveCallSummary>.unmodifiable(next);
  }

  void upsert(ActiveCallSummary summary) {
    if (!summary.isGroup) return;
    final next = Map<String, ActiveCallSummary>.from(state);
    next[summary.conversationId] = summary;
    state = Map<String, ActiveCallSummary>.unmodifiable(next);
  }

  void updateCount({
    required String conversationId,
    required String callId,
    required int participantCount,
    required List<String> participantIds,
  }) {
    final existing = state[conversationId];
    if (existing == null || existing.callId != callId) return;
    final next = Map<String, ActiveCallSummary>.from(state);
    next[conversationId] = existing.copyWith(
      participantCount: participantCount,
      participantIds: participantIds,
    );
    state = Map<String, ActiveCallSummary>.unmodifiable(next);
  }

  void removeByConversation(String conversationId, {String? callId}) {
    final existing = state[conversationId];
    if (existing == null) return;
    if (callId != null && existing.callId != callId) return;
    final next = Map<String, ActiveCallSummary>.from(state)..remove(conversationId);
    state = Map<String, ActiveCallSummary>.unmodifiable(next);
  }
}

final activeGroupCallsProvider =
    NotifierProvider<ActiveGroupCallsNotifier, Map<String, ActiveCallSummary>>(
  ActiveGroupCallsNotifier.new,
);

/// Outcome returned to UI callers when requesting to start/accept/upgrade a call.
enum CallStartFeedback {
  started,
  permissionDenied,
  permissionPermanentlyDenied,
  cameraDeniedAudioFallback,
  busy,
  unavailable,
  failed,
}

/// Account-scoped call state machine driving 1-on-1 and Group voice/video calls.
class CallController extends Notifier<CallState> {
  final RecentIdSet _recentInvites = RecentIdSet(window: const Duration(seconds: 90));
  CallMediaEngine? _media;
  CallForegroundServiceBridge? _fgs;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  StreamSubscription<CallMediaSnapshot>? _mediaSnapshotSub;
  StreamSubscription<CallMediaConnectionEvent>? _mediaConnSub;
  Timer? _ringTimer;
  Timer? _durationTimer;
  Timer? _terminalResetTimer;
  bool _attemptedReconnectRefresh = false;
  bool _cleaningUp = false;

  @override
  CallState build() {
    final scope = ref.watch(accountScopeProvider);
    final socket = ref.watch(chatSocketProvider);
    final media = ref.watch(livekitMediaServiceProvider);
    final fgs = ref.watch(callForegroundServiceProvider);

    _media = media;
    _fgs = fgs;

    _wsSub?.cancel();
    _mediaSnapshotSub?.cancel();
    _mediaConnSub?.cancel();

    fgs.onHangupPressed = () => unawaited(hangUp());

    if (scope != null) {
      _wsSub = socket.callEvents.listen((frame) {
        if (!scope.isOpen || !ref.mounted) return;
        unawaited(handleWsCallEvent(frame));
      });
      _mediaSnapshotSub = media.snapshots.listen(_onMediaSnapshot);
      _mediaConnSub = media.connectionEvents.listen(
        (event) => unawaited(_onMediaConnectionEvent(event)),
      );
    }

    // Never touch `ref` inside `onDispose`: capture `media` and `fgs` directly.
    ref.onDispose(() {
      _wsSub?.cancel();
      _wsSub = null;
      _mediaSnapshotSub?.cancel();
      _mediaSnapshotSub = null;
      _mediaConnSub?.cancel();
      _mediaConnSub = null;
      _ringTimer?.cancel();
      _ringTimer = null;
      _durationTimer?.cancel();
      _durationTimer = null;
      _terminalResetTimer?.cancel();
      _terminalResetTimer = null;
      unawaited(
        _cleanupResourcesWith(
          media: media,
          fgs: fgs,
          clearState: false,
        ),
      );
    });

    return const CallState();
  }

  /// Hydrates all active group calls for the current account (called on WS connect).
  Future<void> refreshActiveCalls() async {
    if (!ref.mounted || ref.read(accountScopeProvider) == null) return;
    try {
      final calls = await ref.read(apiClientProvider).activeCalls();
      if (!ref.mounted) return;
      ref.read(activeGroupCallsProvider.notifier).setAll(calls);
    } catch (error) {
      debugPrint('refreshActiveCalls failed: $error');
    }
  }

  /// Hydrates the active call banner for a single conversation when opened.
  Future<void> refreshConversationActiveCall(String conversationId) async {
    if (!ref.mounted || ref.read(accountScopeProvider) == null) return;
    try {
      final active = await ref
          .read(apiClientProvider)
          .activeCallForConversation(conversationId);
      if (!ref.mounted) return;
      if (active != null && active.isGroup) {
        ref.read(activeGroupCallsProvider.notifier).upsert(active);
      } else {
        ref
            .read(activeGroupCallsProvider.notifier)
            .removeByConversation(conversationId);
      }
    } catch (error) {
      debugPrint('refreshConversationActiveCall($conversationId) failed: $error');
    }
  }

  /// Starts a 1:1 call or starts/converges onto a group call.
  Future<CallStartFeedback> startCall({
    required String conversationId,
    required CallMediaType mediaType,
    required bool isGroup,
    required String title,
    String? peerAvatarUrl,
    bool allowAudioFallback = false,
  }) async {
    if (state.isInCall) {
      if (state.currentConversationId == conversationId) {
        setMinimized(false);
        return CallStartFeedback.started;
      }
      return CallStartFeedback.busy;
    }

    final perms = ref.read(callPermissionServiceProvider);
    final permResult = mediaType == CallMediaType.video
        ? await perms.ensureForVideo()
        : await perms.ensureForVoice();

    if (!permResult.hasMicrophone) {
      return permResult.microphone == CallPermissionOutcome.permanentlyDenied
          ? CallStartFeedback.permissionPermanentlyDenied
          : CallStartFeedback.permissionDenied;
    }

    var effectiveMedia = mediaType;
    if (mediaType == CallMediaType.video && !permResult.hasCamera) {
      if (!allowAudioFallback) {
        return permResult.camera == CallPermissionOutcome.permanentlyDenied
            ? CallStartFeedback.permissionPermanentlyDenied
            : CallStartFeedback.cameraDeniedAudioFallback;
      }
      effectiveMedia = CallMediaType.voice;
    }

    _terminalResetTimer?.cancel();
    _attemptedReconnectRefresh = false;

    state = CallState(
      status: isGroup ? CallStatus.connecting : CallStatus.calling,
      conversationTitle: title,
      peerAvatarUrl: peerAvatarUrl,
      localVideoEnabled: effectiveMedia == CallMediaType.video,
      audioRoute: effectiveMedia == CallMediaType.video
          ? AudioRoute.speaker
          : AudioRoute.earpiece,
    );

    try {
      final grant = await ref.read(apiClientProvider).startCall(
            conversationId,
            mediaType: effectiveMedia,
          );

      final isConvergedActive =
          isGroup || grant.call.status == 'active' || grant.joinedExisting;
      state = state.copyWith(
        status: isConvergedActive ? CallStatus.connecting : CallStatus.calling,
        activeCall: grant.call,
      );

      if (grant.call.isGroup) {
        ref.read(activeGroupCallsProvider.notifier).upsert(grant.call);
      } else if (!isConvergedActive) {
        _startRingingFallbackTimer(grant.call.callId);
      }

      await _connectToLiveKit(
        grant: grant,
        enableVideo: effectiveMedia == CallMediaType.video,
        title: title,
      );
      return CallStartFeedback.started;
    } on ApiException catch (error) {
      if (error.code == 'callee_busy') {
        await _transitionTerminal(
          CallStatus.ended,
          reason: 'Recipient is busy',
        );
        return CallStartFeedback.busy;
      }
      if (error.code == 'calls_unavailable') {
        await _transitionTerminal(
          CallStatus.failed,
          errorMessage: 'Calling is currently unavailable',
        );
        return CallStartFeedback.unavailable;
      }
      await _transitionTerminal(
        CallStatus.failed,
        errorMessage: error.message,
      );
      return CallStartFeedback.failed;
    } catch (error) {
      await _transitionTerminal(
        CallStatus.failed,
        errorMessage: 'Could not start call',
      );
      return CallStartFeedback.failed;
    }
  }

  /// Late-joins an active group call from the chat banner or header.
  Future<CallStartFeedback> joinGroupCall(
    ActiveCallSummary summary, {
    required String title,
    bool enableVideo = false,
  }) async {
    if (state.isInCall) {
      if (state.currentCallId == summary.callId) {
        setMinimized(false);
        return CallStartFeedback.started;
      }
      return CallStartFeedback.busy;
    }

    final perms = ref.read(callPermissionServiceProvider);
    final permResult = enableVideo
        ? await perms.ensureForVideo()
        : await perms.ensureForVoice();
    if (!permResult.hasMicrophone) {
      return permResult.microphone == CallPermissionOutcome.permanentlyDenied
          ? CallStartFeedback.permissionPermanentlyDenied
          : CallStartFeedback.permissionDenied;
    }
    final useVideo = enableVideo && permResult.hasCamera;

    _terminalResetTimer?.cancel();
    _attemptedReconnectRefresh = false;
    state = CallState(
      status: CallStatus.connecting,
      activeCall: summary,
      conversationTitle: title,
      localVideoEnabled: useVideo,
      audioRoute: useVideo ? AudioRoute.speaker : AudioRoute.earpiece,
    );

    try {
      final grant = await ref.read(apiClientProvider).joinCall(summary.callId);
      state = state.copyWith(activeCall: grant.call);
      ref.read(activeGroupCallsProvider.notifier).upsert(grant.call);
      await _connectToLiveKit(
        grant: grant,
        enableVideo: useVideo,
        title: title,
      );
      return CallStartFeedback.started;
    } on ApiException catch (error) {
      if (error.code == 'call_already_ended') {
        ref
            .read(activeGroupCallsProvider.notifier)
            .removeByConversation(summary.conversationId, callId: summary.callId);
      }
      await _transitionTerminal(
        CallStatus.failed,
        errorMessage: error.message,
      );
      return CallStartFeedback.failed;
    } catch (_) {
      await _transitionTerminal(
        CallStatus.failed,
        errorMessage: 'Could not join group call',
      );
      return CallStartFeedback.failed;
    }
  }

  /// Accepts the current incoming 1:1 call (from `/call/incoming` or notification action).
  Future<CallStartFeedback> acceptIncoming({IncomingCallInvite? inviteOverride}) async {
    final invite = inviteOverride ?? state.incomingInvite;
    if (invite == null) return CallStartFeedback.failed;

    if (invite.isExpired) {
      await _dismissIncomingNotification(invite.callId);
      await _transitionTerminal(CallStatus.ended, reason: 'Call missed');
      return CallStartFeedback.failed;
    }

    final perms = ref.read(callPermissionServiceProvider);
    final wantVideo = invite.mediaType == CallMediaType.video;
    final permResult = wantVideo
        ? await perms.ensureForVideo()
        : await perms.ensureForVoice();
    if (!permResult.hasMicrophone) {
      return permResult.microphone == CallPermissionOutcome.permanentlyDenied
          ? CallStartFeedback.permissionPermanentlyDenied
          : CallStartFeedback.permissionDenied;
    }
    final useVideo = wantVideo && permResult.hasCamera;

    _ringTimer?.cancel();
    _terminalResetTimer?.cancel();
    _attemptedReconnectRefresh = false;
    await _dismissIncomingNotification(invite.callId);

    state = CallState(
      status: CallStatus.connecting,
      incomingInvite: invite,
      conversationTitle: invite.callerName,
      peerAvatarUrl: invite.callerAvatarUrl,
      localVideoEnabled: useVideo,
      audioRoute: useVideo ? AudioRoute.speaker : AudioRoute.earpiece,
    );

    try {
      final grant = await ref.read(apiClientProvider).acceptCall(invite.callId);
      state = state.copyWith(
        activeCall: grant.call,
        clearIncomingInvite: true,
      );
      await _connectToLiveKit(
        grant: grant,
        enableVideo: useVideo,
        title: invite.callerName,
      );
      return CallStartFeedback.started;
    } on ApiException catch (error) {
      if (error.code == 'call_already_ended') {
        await _transitionTerminal(CallStatus.ended, reason: 'Call already ended');
        return CallStartFeedback.failed;
      }
      await _transitionTerminal(CallStatus.failed, errorMessage: error.message);
      return CallStartFeedback.failed;
    } catch (_) {
      await _transitionTerminal(
        CallStatus.failed,
        errorMessage: 'Could not connect call',
      );
      return CallStartFeedback.failed;
    }
  }

  /// Declines an incoming 1:1 call.
  Future<void> rejectIncoming({
    String? callId,
    String reason = 'declined',
  }) async {
    final targetId = callId ?? state.incomingInvite?.callId;
    if (targetId == null || targetId.isEmpty) return;

    await _dismissIncomingNotification(targetId);
    try {
      await ref.read(apiClientProvider).rejectCall(targetId, reason: reason);
    } catch (error) {
      debugPrint('rejectCall($targetId) failed: $error');
    }

    if (state.currentCallId == targetId) {
      await _transitionTerminal(
        CallStatus.ended,
        reason: reason == 'busy' ? 'Busy' : 'Declined',
      );
    }
  }

  /// Ends or leaves the current call cleanly across every state.
  Future<void> hangUp() async {
    final current = state;
    if (current.isIdle) return;

    final callId = current.currentCallId;
    final status = current.status;
    final api = ref.read(apiClientProvider);

    if (callId != null && callId.isNotEmpty) {
      await _dismissIncomingNotification(callId);
      try {
        if (status == CallStatus.calling && !current.isGroup) {
          await api.cancelCall(callId);
        } else if (status == CallStatus.ringing) {
          await api.rejectCall(callId, reason: 'declined');
        } else {
          await api.leaveCall(callId);
        }
      } catch (error) {
        debugPrint('hangUp API call failed: $error');
      }
    }

    await _transitionTerminal(CallStatus.ended, reason: 'Call ended');
  }

  /// Toggles local microphone mute without disconnecting.
  Future<void> toggleMute() async {
    if (!state.isLiveSession) return;
    final nextMuted = !state.localAudioMuted;
    try {
      await ref.read(livekitMediaServiceProvider).setMicEnabled(!nextMuted);
      state = state.copyWith(localAudioMuted: nextMuted);
    } catch (error) {
      debugPrint('toggleMute failed: $error');
    }
  }

  /// Mid-call camera upgrade/downgrade. Enforces CAMERA permission BEFORE
  /// upgrading the Android 14+ foreground service type to `microphone|camera`.
  Future<CallPermissionOutcome> toggleCamera() async {
    if (!state.isLiveSession) return CallPermissionOutcome.denied;
    final enable = !state.localVideoEnabled;

    if (enable) {
      final camPerm =
          await ref.read(callPermissionServiceProvider).ensureCameraForUpgrade();
      if (camPerm != CallPermissionOutcome.granted) {
        return camPerm;
      }
    }

    try {
      final media = ref.read(livekitMediaServiceProvider);
      await media.setCameraEnabled(enable);
      state = state.copyWith(localVideoEnabled: enable);

      final fgs = ref.read(callForegroundServiceProvider);
      await fgs.update(
        title: state.conversationTitle.isEmpty
            ? 'Ongoing call'
            : state.conversationTitle,
        subtitle: enable ? 'Video call in progress' : 'Voice call in progress',
        withCamera: enable,
      );
      await fgs.setProximityWakeLock(
        !enable && state.audioRoute == AudioRoute.earpiece,
      );
      if (enable) {
        await _setWakelock(true);
      }
      return CallPermissionOutcome.granted;
    } catch (error) {
      debugPrint('toggleCamera($enable) failed: $error');
      return CallPermissionOutcome.denied;
    }
  }

  Future<void> flipCamera() async {
    if (!state.localVideoEnabled) return;
    try {
      await ref.read(livekitMediaServiceProvider).switchCamera();
    } catch (error) {
      debugPrint('flipCamera failed: $error');
    }
  }

  Future<void> setAudioRoute(AudioRoute route) async {
    if (route == AudioRoute.bluetooth) {
      await ref.read(callPermissionServiceProvider).ensureBluetoothConnect();
    }
    try {
      await ref.read(livekitMediaServiceProvider).setAudioRoute(route);
      state = state.copyWith(audioRoute: route);
      await ref.read(callForegroundServiceProvider).setProximityWakeLock(
            !state.localVideoEnabled && route == AudioRoute.earpiece,
          );
    } catch (error) {
      debugPrint('setAudioRoute($route) failed: $error');
    }
  }

  void setMinimized(bool minimized) {
    if (state.isMinimized == minimized) return;
    state = state.copyWith(isMinimized: minimized);
  }

  void setSubscribedVideoParticipants(Set<String> visibleUserIds) {
    ref
        .read(livekitMediaServiceProvider)
        .setSubscribedVideoParticipants(visibleUserIds);
  }

  /// Processes a live WebSocket call signaling frame.
  Future<void> handleWsCallEvent(Map<String, dynamic> frame) async {
    final type = frame['type']?.toString() ?? '';
    final callId = frame['call_id']?.toString() ?? '';
    final conversationId = frame['conversation_id']?.toString() ?? '';

    switch (type) {
      case 'call_incoming':
        final caller = frame['caller'] is Map<String, dynamic>
            ? frame['caller'] as Map<String, dynamic>
            : const <String, dynamic>{};
        await _onIncomingInvite(
          IncomingCallInvite(
            callId: callId,
            conversationId: conversationId,
            callType: CallType.parse(frame['call_type']?.toString()),
            mediaType: CallMediaType.parse(frame['media_type']?.toString()),
            roomName: frame['room_name']?.toString() ?? '',
            callerId: caller['id']?.toString() ?? '',
            callerName: caller['name']?.toString() ?? 'Incoming call',
            callerAvatarUrl: caller['avatar_url']?.toString(),
            expiresAt: DateTime.tryParse(frame['expires_at']?.toString() ?? '')
                ?.toUtc(),
          ),
        );

      case 'call_accepted':
        if (state.currentCallId == callId && state.status == CallStatus.calling) {
          _ringTimer?.cancel();
          state = state.copyWith(status: CallStatus.connected);
          _startDurationTicker();
        }

      case 'call_answered_elsewhere':
        await _dismissIncomingNotification(callId);
        if (state.currentCallId == callId && state.status == CallStatus.ringing) {
          await _transitionTerminal(
            CallStatus.ended,
            reason: 'Answered on another device',
          );
        }

      case 'call_rejected':
        await _dismissIncomingNotification(callId);
        if (state.currentCallId == callId) {
          final reason = frame['reason']?.toString() == 'busy'
              ? 'Recipient is busy'
              : 'Call declined';
          await _transitionTerminal(CallStatus.ended, reason: reason);
        }

      case 'call_cancelled':
        await _dismissIncomingNotification(callId);
        if (state.currentCallId == callId) {
          await _transitionTerminal(CallStatus.ended, reason: 'Call cancelled');
        }

      case 'call_ended':
        await _dismissIncomingNotification(callId);
        if (state.currentCallId == callId) {
          final raw = frame['reason']?.toString() ?? '';
          final label = raw == 'missed'
              ? 'No answer'
              : raw == 'busy'
                  ? 'Busy'
                  : 'Call ended';
          await _transitionTerminal(CallStatus.ended, reason: label);
        }

      case 'group_call_started':
        final startedBy = frame['started_by'] is Map<String, dynamic>
            ? frame['started_by'] as Map<String, dynamic>
            : const <String, dynamic>{};
        final rawIds = frame['participant_ids'];
        final ids = rawIds is List
            ? rawIds.map((e) => e.toString()).toList()
            : const <String>[];
        ref.read(activeGroupCallsProvider.notifier).upsert(
              ActiveCallSummary(
                callId: callId,
                conversationId: conversationId,
                roomName: 'call_$callId',
                type: CallType.group,
                mediaType: CallMediaType.parse(frame['media_type']?.toString()),
                initiatedBy: startedBy['id']?.toString() ?? '',
                status: 'active',
                participantCount:
                    (frame['participant_count'] as num?)?.toInt() ?? ids.length,
                participantIds: ids,
                startedAt: DateTime.now().toUtc(),
                conversationName: frame['conversation_name']?.toString(),
              ),
            );

      case 'group_call_updated':
        final rawIds = frame['participant_ids'];
        final ids = rawIds is List
            ? rawIds.map((e) => e.toString()).toList()
            : const <String>[];
        final count =
            (frame['participant_count'] as num?)?.toInt() ?? ids.length;
        ref.read(activeGroupCallsProvider.notifier).updateCount(
              conversationId: conversationId,
              callId: callId,
              participantCount: count,
              participantIds: ids,
            );

      case 'group_call_ended':
        ref
            .read(activeGroupCallsProvider.notifier)
            .removeByConversation(conversationId, callId: callId);
        if (state.currentCallId == callId) {
          await _transitionTerminal(CallStatus.ended, reason: 'Group call ended');
        }
    }
  }

  /// Processes a call FCM push delegated to the main isolate (foreground or background-alive).
  Future<void> handleFcmCallEvent(Map<String, dynamic> data) async {
    final type = data['type']?.toString() ?? '';
    final callId = data['call_id']?.toString() ?? '';
    final conversationId = data['conversation_id']?.toString() ?? '';

    if (type == 'call_cancel' || type == 'call_ended') {
      await _dismissIncomingNotification(callId);
      if (state.currentCallId == callId) {
        final reason = data['reason']?.toString() ?? '';
        await _transitionTerminal(
          CallStatus.ended,
          reason: reason == 'answered_elsewhere'
              ? 'Answered on another device'
              : reason == 'missed'
                  ? 'No answer'
                  : 'Call ended',
        );
      }
      return;
    }

    if (type == 'group_call_started') {
      if (conversationId.isEmpty || callId.isEmpty) return;
      ref.read(activeGroupCallsProvider.notifier).upsert(
            ActiveCallSummary(
              callId: callId,
              conversationId: conversationId,
              roomName: 'call_$callId',
              type: CallType.group,
              mediaType: CallMediaType.parse(data['media_type']?.toString()),
              initiatedBy: data['caller_id']?.toString() ?? '',
              status: 'active',
              participantCount: 1,
              participantIds: const [],
              startedAt: DateTime.now().toUtc(),
              conversationName: data['conversation_name']?.toString(),
            ),
          );
      return;
    }

    if (type == 'call_invite') {
      final expiresRaw = int.tryParse(data['expires_at']?.toString() ?? '');
      final expiresAt = expiresRaw != null
          ? DateTime.fromMillisecondsSinceEpoch(expiresRaw, isUtc: true)
          : null;
      await _onIncomingInvite(
        IncomingCallInvite(
          callId: callId,
          conversationId: conversationId,
          callType: CallType.parse(data['call_type']?.toString()),
          mediaType: CallMediaType.parse(data['media_type']?.toString()),
          roomName: 'call_$callId',
          callerId: data['caller_id']?.toString() ?? '',
          callerName: data['caller_name']?.toString() ?? 'Incoming call',
          expiresAt: expiresAt,
        ),
        showFullScreenNotificationIfBackgrounded: true,
      );
    }
  }

  /// Immediate synchronous-friendly teardown called from `SessionLifecycle.stop()`
  /// before signing out or switching accounts.
  Future<void> teardownForLogout() async {
    if (!ref.mounted || state.isIdle) return;
    final callId = state.currentCallId;
    if (callId != null && callId.isNotEmpty) {
      unawaited(_dismissIncomingNotification(callId));
      try {
        await ref.read(apiClientProvider).leaveCall(callId);
      } catch (_) {}
    }
    await _cleanupResources(clearState: true);
  }

  Future<void> _onIncomingInvite(
    IncomingCallInvite invite, {
    bool showFullScreenNotificationIfBackgrounded = false,
  }) async {
    if (invite.callId.isEmpty || invite.isExpired) return;

    // DND suppresses incoming call interrupts.
    final selfStatus = ref.read(currentUserProvider)?.status;
    if (selfStatus == 'dnd') return;

    // Deduplicate WS + FCM delivery for the same callId.
    if (!_recentInvites.add(invite.callId)) return;

    // Busy collision: already in another 1:1 or group call -> auto-reject with busy.
    if (state.isInCall) {
      if (state.currentCallId == invite.callId) return;
      unawaited(rejectIncoming(callId: invite.callId, reason: 'busy'));
      return;
    }

    _terminalResetTimer?.cancel();
    state = CallState(
      status: CallStatus.ringing,
      incomingInvite: invite,
      conversationTitle: invite.callerName,
      peerAvatarUrl: invite.callerAvatarUrl,
    );

    _startRingingFallbackTimer(invite.callId);
    await ref.read(callForegroundServiceProvider).setLockScreenVisible(true);

    if (showFullScreenNotificationIfBackgrounded ||
        ref.read(appLifecycleProvider) != AppLifecycleState.resumed) {
      final accountId = ref.read(accountScopeProvider)?.accountId;
      await ref.read(localNotificationServiceProvider).showIncomingCallNotification(
            callId: invite.callId,
            conversationId: invite.conversationId,
            callerId: invite.callerId,
            callerName: invite.callerName,
            mediaType: invite.mediaType.wireValue,
            accountId: accountId,
            expiresAtMs: invite.expiresAt?.millisecondsSinceEpoch,
          );
    }
  }

  Future<void> _connectToLiveKit({
    required CallJoinGrant grant,
    required bool enableVideo,
    required String title,
  }) async {
    await _configureAudioSession(active: true);
    await _setWakelock(true);

    final fgs = ref.read(callForegroundServiceProvider);
    await fgs.setLockScreenVisible(true);
    await fgs.start(
      title: title.isEmpty ? 'Ongoing call' : title,
      subtitle: enableVideo ? 'Video call in progress' : 'Voice call in progress',
      withCamera: enableVideo,
    );
    await fgs.setProximityWakeLock(!enableVideo);

    await ref.read(livekitMediaServiceProvider).connect(
          url: grant.livekitUrl,
          token: grant.token,
          enableVideo: enableVideo,
        );

    // For group calls or accepted 1:1 calls, move straight to connected once room joins.
    if (grant.call.isGroup || grant.call.status == 'active') {
      state = state.copyWith(status: CallStatus.connected);
      _startDurationTicker();
    }
  }

  void _onMediaSnapshot(CallMediaSnapshot snapshot) {
    if (!state.isLiveSession) return;
    state = state.copyWith(
      participants: snapshot.participants,
      activeSpeakerIds: snapshot.activeSpeakerIds,
      localAudioMuted: snapshot.localAudioMuted,
      localVideoEnabled: snapshot.localVideoEnabled,
      isFrontCamera: snapshot.isFrontCamera,
      audioRoute: snapshot.audioRoute,
      availableAudioRoutes: snapshot.availableAudioRoutes,
      localQuality: snapshot.localQuality,
    );
  }

  Future<void> _onMediaConnectionEvent(CallMediaConnectionEvent event) async {
    if (!state.isLiveSession) return;
    switch (event) {
      case CallMediaConnectionEvent.connected:
        _attemptedReconnectRefresh = false;
        if (state.status == CallStatus.connecting) {
          state = state.copyWith(status: CallStatus.connected);
          _startDurationTicker();
        }
      case CallMediaConnectionEvent.remoteParticipantJoined:
        if (state.status == CallStatus.calling ||
            state.status == CallStatus.connecting) {
          _ringTimer?.cancel();
          state = state.copyWith(status: CallStatus.connected);
          _startDurationTicker();
        }
      case CallMediaConnectionEvent.reconnecting:
        state = state.copyWith(status: CallStatus.reconnecting);
      case CallMediaConnectionEvent.reconnected:
        _attemptedReconnectRefresh = false;
        state = state.copyWith(status: CallStatus.connected);
      case CallMediaConnectionEvent.disconnected:
        final call = state.activeCall;
        if (call == null || _cleaningUp) return;
        // Attempt one fresh-token reconnect before marking failed (network handoff).
        if (!_attemptedReconnectRefresh &&
            (state.status == CallStatus.connected ||
                state.status == CallStatus.reconnecting)) {
          _attemptedReconnectRefresh = true;
          state = state.copyWith(status: CallStatus.reconnecting);
          try {
            final refreshed =
                await ref.read(apiClientProvider).refreshCallToken(call.callId);
            await ref.read(livekitMediaServiceProvider).connect(
                  url: refreshed.livekitUrl,
                  token: refreshed.token,
                  enableVideo: state.localVideoEnabled,
                );
            state = state.copyWith(status: CallStatus.connected);
            return;
          } catch (error) {
            debugPrint('Call reconnect token refresh failed: $error');
          }
        }
        await _transitionTerminal(
          CallStatus.failed,
          errorMessage: 'Connection lost',
        );
    }
  }

  void _startRingingFallbackTimer(String callId) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 42), () {
      if (state.currentCallId != callId) return;
      if (state.status == CallStatus.calling ||
          state.status == CallStatus.ringing) {
        unawaited(_dismissIncomingNotification(callId));
        unawaited(_transitionTerminal(CallStatus.ended, reason: 'No answer'));
      }
    });
  }

  void _startDurationTicker() {
    if (_durationTimer != null) return;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.status == CallStatus.connected ||
          state.status == CallStatus.reconnecting) {
        state = state.copyWith(
          elapsed: state.elapsed + const Duration(seconds: 1),
        );
      }
    });
  }

  Future<void> _transitionTerminal(
    CallStatus terminalStatus, {
    String? reason,
    String? errorMessage,
  }) async {
    assert(terminalStatus == CallStatus.ended || terminalStatus == CallStatus.failed);
    await _cleanupResources(clearState: false);
    state = state.copyWith(
      status: terminalStatus,
      endReason: reason,
      errorMessage: errorMessage,
      isMinimized: false,
      participants: const [],
      activeSpeakerIds: const {},
    );

    _terminalResetTimer?.cancel();
    _terminalResetTimer = Timer(const Duration(milliseconds: 1800), () {
      if (state.status == CallStatus.ended || state.status == CallStatus.failed) {
        state = const CallState();
      }
    });
  }

  Future<void> _cleanupResources({required bool clearState}) async {
    await _cleanupResourcesWith(
      media: _media,
      fgs: _fgs,
      clearState: clearState,
    );
  }

  Future<void> _cleanupResourcesWith({
    required CallMediaEngine? media,
    required CallForegroundServiceBridge? fgs,
    required bool clearState,
  }) async {
    if (_cleaningUp) return;
    _cleaningUp = true;
    try {
      _ringTimer?.cancel();
      _ringTimer = null;
      _durationTimer?.cancel();
      _durationTimer = null;

      if (media != null) {
        try {
          await media.disconnectAndDispose();
        } catch (error) {
          debugPrint('LiveKit cleanup failed: $error');
        }
      }

      await _configureAudioSession(active: false);

      if (fgs != null) {
        await fgs.stop();
        await fgs.setLockScreenVisible(false);
        await fgs.setProximityWakeLock(false);
      }

      await _setWakelock(false);

      if (clearState && ref.mounted) {
        _terminalResetTimer?.cancel();
        _terminalResetTimer = null;
        state = const CallState();
      }
    } finally {
      _cleaningUp = false;
    }
  }

  Future<void> _configureAudioSession({required bool active}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final session = await AudioSession.instance;
      if (active) {
        await session.configure(
          const AudioSessionConfiguration(
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.speech,
              usage: AndroidAudioUsage.voiceCommunication,
            ),
            androidAudioFocusGainType:
                AndroidAudioFocusGainType.gainTransient,
            androidWillPauseWhenDucked: true,
          ),
        );
      }
      await session.setActive(active);
    } catch (error) {
      debugPrint('AudioSession($active) failed: $error');
    }
  }

  Future<void> _setWakelock(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('WakelockPlus($enabled) failed: $error');
    }
  }

  Future<void> _dismissIncomingNotification(String callId) async {
    if (callId.isEmpty) return;
    try {
      await ref.read(localNotificationServiceProvider).cancelCallNotification(callId);
    } catch (_) {}
  }
}

final callControllerProvider = NotifierProvider<CallController, CallState>(
  CallController.new,
);
