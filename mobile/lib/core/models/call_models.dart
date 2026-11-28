import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart'
    show ConnectionQuality, VideoTrack;

enum CallType {
  oneOnOne('1on1'),
  group('group');

  const CallType(this.wireValue);
  final String wireValue;

  static CallType parse(String? raw) =>
      raw == 'group' ? CallType.group : CallType.oneOnOne;
}

enum CallMediaType {
  voice('voice'),
  video('video');

  const CallMediaType(this.wireValue);
  final String wireValue;

  static CallMediaType parse(String? raw) =>
      raw == 'video' ? CallMediaType.video : CallMediaType.voice;
}

enum CallStatus {
  idle,
  calling,
  ringing,
  connecting,
  connected,
  reconnecting,
  ended,
  failed,
}

enum AudioRoute {
  earpiece,
  speaker,
  bluetooth,
}

@immutable
class ActiveCallSummary {
  const ActiveCallSummary({
    required this.callId,
    required this.conversationId,
    required this.roomName,
    required this.type,
    required this.mediaType,
    required this.initiatedBy,
    required this.status,
    required this.participantCount,
    required this.participantIds,
    required this.startedAt,
    this.ringExpiresAt,
    this.answeredAt,
    this.endedAt,
    this.endReason,
    this.conversationName,
  });

  final String callId;
  final String conversationId;
  final String roomName;
  final CallType type;
  final CallMediaType mediaType;
  final String initiatedBy;
  final String status;
  final int participantCount;
  final List<String> participantIds;
  final DateTime startedAt;
  final DateTime? ringExpiresAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
  final String? endReason;
  final String? conversationName;

  bool get isGroup => type == CallType.group;
  bool get isVideo => mediaType == CallMediaType.video;

  ActiveCallSummary copyWith({
    int? participantCount,
    List<String>? participantIds,
    String? status,
    String? conversationName,
  }) {
    return ActiveCallSummary(
      callId: callId,
      conversationId: conversationId,
      roomName: roomName,
      type: type,
      mediaType: mediaType,
      initiatedBy: initiatedBy,
      status: status ?? this.status,
      participantCount: participantCount ?? this.participantCount,
      participantIds: participantIds ?? this.participantIds,
      startedAt: startedAt,
      ringExpiresAt: ringExpiresAt,
      answeredAt: answeredAt,
      endedAt: endedAt,
      endReason: endReason,
      conversationName: conversationName ?? this.conversationName,
    );
  }

  factory ActiveCallSummary.fromJson(Map<String, dynamic> json) {
    final rawParticipants = json['participant_ids'];
    final ids = rawParticipants is List
        ? rawParticipants.map((e) => e.toString()).toList()
        : const <String>[];
    return ActiveCallSummary(
      callId: (json['id'] ?? json['call_id'])?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      roomName: json['room_name']?.toString() ?? '',
      type: CallType.parse(json['type']?.toString()),
      mediaType: CallMediaType.parse(json['media_type']?.toString()),
      initiatedBy: json['initiated_by']?.toString() ?? '',
      status: json['status']?.toString() ?? 'active',
      participantCount:
          (json['participant_count'] as num?)?.toInt() ?? ids.length,
      participantIds: ids,
      startedAt:
          DateTime.tryParse(json['started_at']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
      ringExpiresAt:
          DateTime.tryParse(json['ring_expires_at']?.toString() ?? '')?.toUtc(),
      answeredAt:
          DateTime.tryParse(json['answered_at']?.toString() ?? '')?.toUtc(),
      endedAt: DateTime.tryParse(json['ended_at']?.toString() ?? '')?.toUtc(),
      endReason: json['end_reason']?.toString(),
      conversationName: json['conversation_name']?.toString(),
    );
  }
}

@immutable
class CallJoinGrant {
  const CallJoinGrant({
    required this.call,
    required this.livekitUrl,
    required this.token,
    required this.expiresIn,
    this.joinedExisting = false,
  });

  final ActiveCallSummary call;
  final String livekitUrl;
  final String token;
  final int expiresIn;
  final bool joinedExisting;

  factory CallJoinGrant.fromJson(Map<String, dynamic> json) {
    return CallJoinGrant(
      call: ActiveCallSummary.fromJson(json['call'] as Map<String, dynamic>),
      livekitUrl: json['livekit_url']?.toString() ?? '',
      token: json['token']?.toString() ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 600,
      joinedExisting: json['joined_existing'] == true,
    );
  }
}

@immutable
class CallTokenRefresh {
  const CallTokenRefresh({
    required this.livekitUrl,
    required this.token,
    required this.expiresIn,
  });

  final String livekitUrl;
  final String token;
  final int expiresIn;

  factory CallTokenRefresh.fromJson(Map<String, dynamic> json) {
    return CallTokenRefresh(
      livekitUrl: json['livekit_url']?.toString() ?? '',
      token: json['token']?.toString() ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 600,
    );
  }
}

@immutable
class IncomingCallInvite {
  const IncomingCallInvite({
    required this.callId,
    required this.conversationId,
    required this.callType,
    required this.mediaType,
    required this.roomName,
    required this.callerId,
    required this.callerName,
    this.callerAvatarUrl,
    this.expiresAt,
  });

  final String callId;
  final String conversationId;
  final CallType callType;
  final CallMediaType mediaType;
  final String roomName;
  final String callerId;
  final String callerName;
  final String? callerAvatarUrl;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);
}

@immutable
class CallParticipantView {
  const CallParticipantView({
    required this.userId,
    required this.displayName,
    required this.isLocal,
    this.avatarUrl,
    this.videoTrack,
    this.audioMuted = false,
    this.videoEnabled = false,
    this.isSpeaking = false,
    this.connectionQuality = ConnectionQuality.good,
  });

  final String userId;
  final String displayName;
  final bool isLocal;
  final String? avatarUrl;
  final VideoTrack? videoTrack;
  final bool audioMuted;
  final bool videoEnabled;
  final bool isSpeaking;
  final ConnectionQuality connectionQuality;
}

@immutable
class CallMediaSnapshot {
  const CallMediaSnapshot({
    this.participants = const [],
    this.activeSpeakerIds = const {},
    this.localAudioMuted = false,
    this.localVideoEnabled = false,
    this.isFrontCamera = true,
    this.audioRoute = AudioRoute.earpiece,
    this.availableAudioRoutes = const [AudioRoute.earpiece, AudioRoute.speaker],
    this.localQuality = ConnectionQuality.good,
  });

  final List<CallParticipantView> participants;
  final Set<String> activeSpeakerIds;
  final bool localAudioMuted;
  final bool localVideoEnabled;
  final bool isFrontCamera;
  final AudioRoute audioRoute;
  final List<AudioRoute> availableAudioRoutes;
  final ConnectionQuality localQuality;
}

enum CallMediaConnectionEvent {
  connected,
  reconnecting,
  reconnected,
  disconnected,
  remoteParticipantJoined,
}

@immutable
class CallState {
  const CallState({
    this.status = CallStatus.idle,
    this.activeCall,
    this.incomingInvite,
    this.conversationTitle = '',
    this.peerAvatarUrl,
    this.localAudioMuted = false,
    this.localVideoEnabled = false,
    this.isFrontCamera = true,
    this.audioRoute = AudioRoute.earpiece,
    this.availableAudioRoutes = const [AudioRoute.earpiece, AudioRoute.speaker],
    this.participants = const [],
    this.activeSpeakerIds = const {},
    this.localQuality = ConnectionQuality.good,
    this.elapsed = Duration.zero,
    this.endReason,
    this.errorMessage,
    this.isMinimized = false,
  });

  final CallStatus status;
  final ActiveCallSummary? activeCall;
  final IncomingCallInvite? incomingInvite;
  final String conversationTitle;
  final String? peerAvatarUrl;
  final bool localAudioMuted;
  final bool localVideoEnabled;
  final bool isFrontCamera;
  final AudioRoute audioRoute;
  final List<AudioRoute> availableAudioRoutes;
  final List<CallParticipantView> participants;
  final Set<String> activeSpeakerIds;
  final ConnectionQuality localQuality;
  final Duration elapsed;
  final String? endReason;
  final String? errorMessage;
  final bool isMinimized;

  bool get isIdle => status == CallStatus.idle;
  bool get isInCall =>
      status == CallStatus.calling ||
      status == CallStatus.ringing ||
      status == CallStatus.connecting ||
      status == CallStatus.connected ||
      status == CallStatus.reconnecting;
  bool get isLiveSession =>
      status == CallStatus.calling ||
      status == CallStatus.connecting ||
      status == CallStatus.connected ||
      status == CallStatus.reconnecting;
  String? get currentCallId => activeCall?.callId ?? incomingInvite?.callId;
  String? get currentConversationId =>
      activeCall?.conversationId ?? incomingInvite?.conversationId;
  bool get isGroup =>
      activeCall?.isGroup ?? (incomingInvite?.callType == CallType.group);

  CallState copyWith({
    CallStatus? status,
    ActiveCallSummary? activeCall,
    bool clearActiveCall = false,
    IncomingCallInvite? incomingInvite,
    bool clearIncomingInvite = false,
    String? conversationTitle,
    String? peerAvatarUrl,
    bool clearPeerAvatar = false,
    bool? localAudioMuted,
    bool? localVideoEnabled,
    bool? isFrontCamera,
    AudioRoute? audioRoute,
    List<AudioRoute>? availableAudioRoutes,
    List<CallParticipantView>? participants,
    Set<String>? activeSpeakerIds,
    ConnectionQuality? localQuality,
    Duration? elapsed,
    String? endReason,
    bool clearEndReason = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isMinimized,
  }) {
    return CallState(
      status: status ?? this.status,
      activeCall: clearActiveCall ? null : (activeCall ?? this.activeCall),
      incomingInvite: clearIncomingInvite
          ? null
          : (incomingInvite ?? this.incomingInvite),
      conversationTitle: conversationTitle ?? this.conversationTitle,
      peerAvatarUrl:
          clearPeerAvatar ? null : (peerAvatarUrl ?? this.peerAvatarUrl),
      localAudioMuted: localAudioMuted ?? this.localAudioMuted,
      localVideoEnabled: localVideoEnabled ?? this.localVideoEnabled,
      isFrontCamera: isFrontCamera ?? this.isFrontCamera,
      audioRoute: audioRoute ?? this.audioRoute,
      availableAudioRoutes: availableAudioRoutes ?? this.availableAudioRoutes,
      participants: participants ?? this.participants,
      activeSpeakerIds: activeSpeakerIds ?? this.activeSpeakerIds,
      localQuality: localQuality ?? this.localQuality,
      elapsed: elapsed ?? this.elapsed,
      endReason: clearEndReason ? null : (endReason ?? this.endReason),
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      isMinimized: isMinimized ?? this.isMinimized,
    );
  }
}
