import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../core/models/call_models.dart';

/// Seam over the LiveKit WebRTC SDK so `CallController` can be thoroughly unit
/// tested on the host VM without native WebRTC libraries.
abstract class CallMediaEngine {
  Stream<CallMediaSnapshot> get snapshots;
  Stream<CallMediaConnectionEvent> get connectionEvents;
  CallMediaSnapshot get currentSnapshot;

  Future<void> connect({
    required String url,
    required String token,
    required bool enableVideo,
  });

  Future<void> setMicEnabled(bool enabled);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> switchCamera();
  Future<void> setAudioRoute(AudioRoute route);
  Future<List<AudioRoute>> refreshAudioRoutes();
  void setSubscribedVideoParticipants(Set<String> visibleUserIds);
  Future<void> disconnectAndDispose();
}

/// Owns the LiveKit `Room` lifecycle, media tracks, Simulcast/Dynacast options,
/// audio output routing, and visible-page remote video subscription gating.
class LiveKitMediaService implements CallMediaEngine {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  CameraPosition _cameraPosition = CameraPosition.front;
  AudioRoute _audioRoute = AudioRoute.earpiece;
  List<AudioRoute> _availableRoutes = const [
    AudioRoute.earpiece,
    AudioRoute.speaker,
  ];
  Set<String> _activeSpeakers = const {};
  Set<String>? _subscribedVideoUserIds;
  bool _disposed = false;

  CallMediaSnapshot _currentSnapshot = const CallMediaSnapshot();

  final StreamController<CallMediaSnapshot> _snapshotController =
      StreamController<CallMediaSnapshot>.broadcast();
  final StreamController<CallMediaConnectionEvent> _connectionController =
      StreamController<CallMediaConnectionEvent>.broadcast();

  @override
  Stream<CallMediaSnapshot> get snapshots => _snapshotController.stream;

  @override
  Stream<CallMediaConnectionEvent> get connectionEvents =>
      _connectionController.stream;

  @override
  CallMediaSnapshot get currentSnapshot => _currentSnapshot;

  @override
  Future<void> connect({
    required String url,
    required String token,
    required bool enableVideo,
  }) async {
    await disconnectAndDispose();
    if (_disposed) return;

    _cameraPosition = CameraPosition.front;
    _audioRoute = enableVideo ? AudioRoute.speaker : AudioRoute.earpiece;
    _subscribedVideoUserIds = null;

    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: const AudioPublishOptions(
          dtx: true,
          red: true,
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,
          videoCodec: 'vp8',
          videoEncoding: VideoParametersPresets.h540_169.encoding,
        ),
        defaultCameraCaptureOptions: const CameraCaptureOptions(
          cameraPosition: CameraPosition.front,
          params: VideoParametersPresets.h540_169,
        ),
      ),
    );

    _room = room;
    _listener = room.createListener();
    _wireRoomEvents(_listener!);

    await room.connect(
      url,
      token,
      fastConnectOptions: FastConnectOptions(
        microphone: const TrackOption(enabled: true),
        camera: TrackOption(enabled: enableVideo),
      ),
    );

    await refreshAudioRoutes();
    await setAudioRoute(_audioRoute);
    _emitSnapshot();
    _emitConnection(CallMediaConnectionEvent.connected);
  }

  void _wireRoomEvents(EventsListener<RoomEvent> listener) {
    listener
      ..on<RoomReconnectingEvent>((_) {
        _emitConnection(CallMediaConnectionEvent.reconnecting);
        _emitSnapshot();
      })
      ..on<RoomReconnectedEvent>((_) {
        _emitConnection(CallMediaConnectionEvent.reconnected);
        _emitSnapshot();
      })
      ..on<RoomDisconnectedEvent>((_) {
        _emitConnection(CallMediaConnectionEvent.disconnected);
        _emitSnapshot();
      })
      ..on<ParticipantConnectedEvent>((_) {
        _emitConnection(CallMediaConnectionEvent.remoteParticipantJoined);
        _applyVideoSubscriptions();
        _emitSnapshot();
      })
      ..on<ParticipantDisconnectedEvent>((_) => _emitSnapshot())
      ..on<TrackPublishedEvent>((_) {
        _applyVideoSubscriptions();
        _emitSnapshot();
      })
      ..on<TrackUnpublishedEvent>((_) => _emitSnapshot())
      ..on<TrackSubscribedEvent>((_) => _emitSnapshot())
      ..on<TrackUnsubscribedEvent>((_) => _emitSnapshot())
      ..on<TrackMutedEvent>((_) => _emitSnapshot())
      ..on<TrackUnmutedEvent>((_) => _emitSnapshot())
      ..on<LocalTrackPublishedEvent>((_) => _emitSnapshot())
      ..on<LocalTrackUnpublishedEvent>((_) => _emitSnapshot())
      ..on<ParticipantConnectionQualityUpdatedEvent>((_) => _emitSnapshot())
      ..on<ActiveSpeakersChangedEvent>((event) {
        _activeSpeakers = event.speakers.map((p) => p.identity).toSet();
        _emitSnapshot();
      });
  }

  @override
  Future<void> setMicEnabled(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setMicrophoneEnabled(enabled);
    _emitSnapshot();
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setCameraEnabled(
      enabled,
      cameraCaptureOptions: CameraCaptureOptions(
        cameraPosition: _cameraPosition,
        params: VideoParametersPresets.h540_169,
      ),
    );
    _emitSnapshot();
  }

  @override
  Future<void> switchCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = _cameraPosition == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;
    for (final pub in local.videoTrackPublications) {
      final track = pub.track;
      if (track is LocalVideoTrack) {
        await track.setCameraPosition(next);
        _cameraPosition = next;
        _emitSnapshot();
        return;
      }
    }
    _cameraPosition = next;
    _emitSnapshot();
  }

  @override
  Future<List<AudioRoute>> refreshAudioRoutes() async {
    final routes = <AudioRoute>[AudioRoute.earpiece, AudioRoute.speaker];
    try {
      final devices = await Hardware.instance.audioOutputs();
      final hasBluetooth = devices.any(
        (d) =>
            d.label.toLowerCase().contains('bluetooth') ||
            d.deviceId.toLowerCase().contains('bluetooth'),
      );
      if (hasBluetooth) {
        routes.add(AudioRoute.bluetooth);
      } else if (_audioRoute == AudioRoute.bluetooth) {
        _audioRoute = AudioRoute.earpiece;
      }
    } catch (error) {
      debugPrint('LiveKit audioOutputs enumeration failed: $error');
    }
    _availableRoutes = routes;
    _emitSnapshot();
    return routes;
  }

  @override
  Future<void> setAudioRoute(AudioRoute route) async {
    _audioRoute = route;
    try {
      switch (route) {
        case AudioRoute.speaker:
          await AudioManager.instance.setSpeakerOutputPreferred(true);
        case AudioRoute.earpiece:
          await AudioManager.instance.setSpeakerOutputPreferred(false);
        case AudioRoute.bluetooth:
          await AudioManager.instance.setSpeakerOutputPreferred(false);
          final devices = await Hardware.instance.audioOutputs();
          for (final device in devices) {
            if (device.label.toLowerCase().contains('bluetooth') ||
                device.deviceId.toLowerCase().contains('bluetooth')) {
              await Hardware.instance.selectAudioOutput(device);
              break;
            }
          }
      }
    } catch (error) {
      debugPrint('LiveKit setAudioRoute($route) failed: $error');
    }
    _emitSnapshot();
  }

  @override
  void setSubscribedVideoParticipants(Set<String> visibleUserIds) {
    _subscribedVideoUserIds = Set<String>.from(visibleUserIds);
    _applyVideoSubscriptions();
  }

  void _applyVideoSubscriptions() {
    final room = _room;
    final allowed = _subscribedVideoUserIds;
    if (room == null || allowed == null) return;

    for (final remote in room.remoteParticipants.values) {
      final shouldSubscribe = allowed.contains(remote.identity);
      for (final pub in remote.videoTrackPublications) {
        try {
          if (shouldSubscribe && !pub.subscribed) {
            unawaited(pub.subscribe());
          } else if (!shouldSubscribe && pub.subscribed) {
            unawaited(pub.unsubscribe());
          }
        } catch (error) {
          debugPrint('LiveKit video subscription toggle failed: $error');
        }
      }
    }
  }

  @override
  Future<void> disconnectAndDispose() async {
    final listener = _listener;
    _listener = null;
    final room = _room;
    _room = null;
    _activeSpeakers = const {};
    _subscribedVideoUserIds = null;

    if (listener != null) {
      try {
        await listener.dispose();
      } catch (error) {
        debugPrint('LiveKit listener dispose failed: $error');
      }
    }

    if (room != null) {
      final local = room.localParticipant;
      if (local != null) {
        for (final pub in [...local.trackPublications.values]) {
          final track = pub.track;
          try {
            await track?.stop();
            await track?.dispose();
          } catch (_) {}
        }
      }
      try {
        await room.disconnect();
      } catch (error) {
        debugPrint('LiveKit room disconnect failed: $error');
      }
      try {
        await room.dispose();
      } catch (error) {
        debugPrint('LiveKit room dispose failed: $error');
      }
    }

    _currentSnapshot = const CallMediaSnapshot();
    if (!_disposed && !_snapshotController.isClosed) {
      _snapshotController.add(_currentSnapshot);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await disconnectAndDispose();
    await _snapshotController.close();
    await _connectionController.close();
  }

  void _emitConnection(CallMediaConnectionEvent event) {
    if (_disposed || _connectionController.isClosed) return;
    _connectionController.add(event);
  }

  void _emitSnapshot() {
    if (_disposed || _snapshotController.isClosed) return;
    final room = _room;
    if (room == null) {
      _currentSnapshot = const CallMediaSnapshot();
      _snapshotController.add(_currentSnapshot);
      return;
    }

    final views = <CallParticipantView>[];
    final local = room.localParticipant;
    if (local != null) {
      views.add(_toParticipantView(local, isLocal: true));
    }
    for (final remote in room.remoteParticipants.values) {
      views.add(_toParticipantView(remote, isLocal: false));
    }

    final localAudioMuted = !(local?.isMicrophoneEnabled() ?? false);
    final localVideoEnabled = local?.isCameraEnabled() ?? false;

    _currentSnapshot = CallMediaSnapshot(
      participants: views,
      activeSpeakerIds: Set<String>.unmodifiable(_activeSpeakers),
      localAudioMuted: localAudioMuted,
      localVideoEnabled: localVideoEnabled,
      isFrontCamera: _cameraPosition == CameraPosition.front,
      audioRoute: _audioRoute,
      availableAudioRoutes: List<AudioRoute>.unmodifiable(_availableRoutes),
      localQuality: local?.connectionQuality ?? ConnectionQuality.good,
    );
    _snapshotController.add(_currentSnapshot);
  }

  CallParticipantView _toParticipantView(
    Participant participant, {
    required bool isLocal,
  }) {
    VideoTrack? videoTrack;
    var videoEnabled = false;
    for (final pub in participant.videoTrackPublications) {
      if (pub.source == TrackSource.camera &&
          pub.track is VideoTrack &&
          !pub.muted) {
        videoTrack = pub.track as VideoTrack;
        videoEnabled = true;
        break;
      }
    }
    final audioMuted = !participant.isMicrophoneEnabled();
    String? avatarUrl;
    final meta = participant.metadata;
    if (meta != null && meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map<String, dynamic>) {
          avatarUrl = decoded['avatar_url']?.toString();
        }
      } catch (_) {}
    }

    return CallParticipantView(
      userId: participant.identity,
      displayName: participant.name.isNotEmpty ? participant.name : 'Participant',
      isLocal: isLocal,
      avatarUrl: avatarUrl,
      videoTrack: videoTrack,
      audioMuted: audioMuted,
      videoEnabled: videoEnabled,
      isSpeaking: _activeSpeakers.contains(participant.identity),
      connectionQuality: participant.connectionQuality,
    );
  }
}
