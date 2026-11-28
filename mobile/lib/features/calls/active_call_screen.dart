import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/call_models.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/user_avatar.dart';
import 'call_controller.dart';
import 'call_permissions.dart';
import 'widgets/active_call_banner.dart';
import 'widgets/call_controls_bar.dart';
import 'widgets/call_participants_sheet.dart';
import 'widgets/group_call_grid.dart';

/// Active call screen (`/call/active`) supporting:
/// - Outgoing 1:1 `calling` state
/// - 1:1 Voice call (avatar + elapsed timer + connection quality)
/// - 1:1 Video call (full-screen remote video + draggable local PiP)
/// - Group call (`GroupCallGrid` + participants sheet)
class ActiveCallScreen extends ConsumerStatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  ConsumerState<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends ConsumerState<ActiveCallScreen> {
  Offset _pipOffset = const Offset(16, 88);

  Future<void> _onToggleCamera() async {
    final outcome =
        await ref.read(callControllerProvider.notifier).toggleCamera();
    if (!mounted) return;
    if (outcome == CallPermissionOutcome.permanentlyDenied) {
      final perms = ref.read(callPermissionServiceProvider);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Camera permission required'),
          content: const Text(
            'Enable camera access in Android app settings to turn on video.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(perms.openSettings());
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    } else if (outcome == CallPermissionOutcome.denied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera permission denied. Continuing with audio only.'),
        ),
      );
    }
  }

  void _minimize() {
    ref.read(callControllerProvider.notifier).setMinimized(true);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _showParticipantsSheet(List<CallParticipantView> participants) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => CallParticipantsSheet(participants: participants),
    );
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    final controller = ref.read(callControllerProvider.notifier);

    final statusLabel = switch (call.status) {
      CallStatus.calling => 'Ringing...',
      CallStatus.connecting => 'Connecting...',
      CallStatus.connected => formatCallDuration(call.elapsed),
      CallStatus.reconnecting => 'Reconnecting...',
      CallStatus.ended => call.endReason ?? 'Call ended',
      CallStatus.failed => call.errorMessage ?? 'Call failed',
      _ => '',
    };

    final title = call.conversationTitle.isNotEmpty
        ? call.conversationTitle
        : (call.isGroup ? 'Group call' : 'Voice call');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && call.isLiveSession) {
          _minimize();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Main media canvas
              Positioned.fill(
                child: call.isGroup
                    ? Padding(
                        padding: const EdgeInsets.only(top: 64, bottom: 96),
                        child: GroupCallGrid(
                          participants: call.participants,
                          onVisibleParticipantsChanged:
                              controller.setSubscribedVideoParticipants,
                        ),
                      )
                    : _OneOnOneCanvas(
                        call: call,
                        title: title,
                        statusLabel: statusLabel,
                        pipOffset: _pipOffset,
                        onPipDragged: (delta, size) {
                          setState(() {
                            _pipOffset = Offset(
                              (_pipOffset.dx + delta.dx)
                                  .clamp(8.0, (size.width - 120).clamp(8.0, size.width)),
                              (_pipOffset.dy + delta.dy)
                                  .clamp(68.0, (size.height - 260).clamp(68.0, size.height)),
                            );
                          });
                        },
                      ),
              ),

              // Top overlay bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.72),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      if (call.isLiveSession)
                        IconButton(
                          tooltip: 'Minimize call',
                          icon: const Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.white,
                          ),
                          onPressed: _minimize,
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (statusLabel.isNotEmpty)
                              Row(
                                children: [
                                  _ConnectionQualityPill(
                                    quality: call.localQuality,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    statusLabel,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      if (call.isGroup)
                        ActionChip(
                          backgroundColor: Colors.white.withValues(alpha: 0.14),
                          side: BorderSide.none,
                          avatar: const Icon(
                            Icons.people,
                            color: Colors.white,
                            size: 16,
                          ),
                          label: Text(
                            '${call.participants.length}',
                            style: const TextStyle(color: Colors.white),
                          ),
                          onPressed: () =>
                              _showParticipantsSheet(call.participants),
                        ),
                    ],
                  ),
                ),
              ),

              // Inline reconnecting banner
              if (call.status == CallStatus.reconnecting)
                Positioned(
                  top: 66,
                  left: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.statusIdle.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black87,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Connection unstable · Reconnecting...',
                          style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Bottom call controls bar
              Positioned(
                left: 12,
                right: 12,
                bottom: 20,
                child: Center(
                  child: CallControlsBar(
                    audioMuted: call.localAudioMuted,
                    videoEnabled: call.localVideoEnabled,
                    audioRoute: call.audioRoute,
                    availableAudioRoutes: call.availableAudioRoutes,
                    isGroup: call.isGroup,
                    onToggleMute: () => unawaited(controller.toggleMute()),
                    onToggleCamera: () => unawaited(_onToggleCamera()),
                    onFlipCamera: () => unawaited(controller.flipCamera()),
                    onSelectAudioRoute: (route) =>
                        unawaited(controller.setAudioRoute(route)),
                    onShowParticipants: call.isGroup
                        ? () => _showParticipantsSheet(call.participants)
                        : null,
                    onHangUp: () => unawaited(controller.hangUp()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OneOnOneCanvas extends StatelessWidget {
  const _OneOnOneCanvas({
    required this.call,
    required this.title,
    required this.statusLabel,
    required this.pipOffset,
    required this.onPipDragged,
  });

  final CallState call;
  final String title;
  final String statusLabel;
  final Offset pipOffset;
  final void Function(Offset delta, Size canvasSize) onPipDragged;

  @override
  Widget build(BuildContext context) {
    CallParticipantView? remote;
    CallParticipantView? local;
    for (final p in call.participants) {
      if (p.isLocal) {
        local = p;
      } else {
        remote ??= p;
      }
    }

    final remoteTrack =
        (remote != null && remote.videoEnabled) ? remote.videoTrack : null;
    final localTrack =
        (local != null && local.videoEnabled) ? local.videoTrack : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (remoteTrack != null)
              VideoTrackRenderer(
                remoteTrack,
                fit: VideoViewFit.cover,
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UserAvatarWithStatus(
                      avatarKey: remote?.avatarUrl ?? call.peerAvatarUrl,
                      name: remote?.displayName ?? title,
                      radius: 58,
                      showStatus: false,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      remote?.displayName ?? title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      statusLabel,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),

            if (localTrack != null)
              Positioned(
                left: pipOffset.dx,
                top: pipOffset.dy,
                child: GestureDetector(
                  onPanUpdate: (details) => onPipDragged(details.delta, size),
                  child: Container(
                    width: 112,
                    height: 156,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2C34),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: VideoTrackRenderer(
                      localTrack,
                      fit: VideoViewFit.cover,
                      mirrorMode: call.isFrontCamera
                          ? VideoViewMirrorMode.mirror
                          : VideoViewMirrorMode.off,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ConnectionQualityPill extends StatelessWidget {
  const _ConnectionQualityPill({required this.quality});

  final ConnectionQuality quality;

  @override
  Widget build(BuildContext context) {
    final color = switch (quality) {
      ConnectionQuality.excellent || ConnectionQuality.good => AppColors.statusOnline,
      ConnectionQuality.poor => AppColors.statusIdle,
      ConnectionQuality.lost => AppColors.statusDnd,
      ConnectionQuality.unknown => AppColors.statusOffline,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
