import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/call_models.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/user_avatar.dart';
import 'call_controller.dart';

/// Full-screen incoming call UI (`/call/incoming`).
class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_handling) return;
    setState(() => _handling = true);
    try {
      final result =
          await ref.read(callControllerProvider.notifier).acceptIncoming();
      if (!mounted) return;
      if (result == CallStartFeedback.permissionPermanentlyDenied) {
        await _showPermissionSettingsDialog();
      } else if (result == CallStartFeedback.permissionDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required to answer calls.'),
          ),
        );
      } else if (result == CallStartFeedback.started) {
        context.go('/call/active');
      }
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

  Future<void> _decline() async {
    if (_handling) return;
    setState(() => _handling = true);
    try {
      await ref.read(callControllerProvider.notifier).rejectIncoming();
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

  Future<void> _showPermissionSettingsDialog() async {
    final perms = ref.read(callPermissionServiceProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Microphone permission required'),
        content: const Text(
          'CP Chat needs microphone access to answer calls. '
          'Please enable it in Android app settings.',
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
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    final invite = call.incomingInvite;
    final callerName =
        invite?.callerName ?? (call.conversationTitle.isNotEmpty ? call.conversationTitle : 'Incoming call');
    final isVideo = invite?.mediaType == CallMediaType.video;
    final subtitle = call.status == CallStatus.ended
        ? (call.endReason ?? 'Call ended')
        : (isVideo ? 'Incoming video call' : 'Incoming voice call');

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B141A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
            child: Column(
              children: [
                const SizedBox(height: 24),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  callerName,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 1.0 + (_pulseController.value * 0.14);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.scale(
                          scale: scale,
                          child: Container(
                            width: 148,
                            height: 148,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.whatsappEmerald
                                  .withValues(alpha: 0.18),
                            ),
                          ),
                        ),
                        child!,
                      ],
                    );
                  },
                  child: UserAvatarWithStatus(
                    avatarKey: invite?.callerAvatarUrl ?? call.peerAvatarUrl,
                    name: callerName,
                    radius: 56,
                    showStatus: false,
                  ),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _IncomingActionButton(
                      label: 'Decline',
                      icon: Icons.call_end,
                      color: Colors.red.shade600,
                      onPressed: _handling ? null : _decline,
                    ),
                    _IncomingActionButton(
                      label: isVideo ? 'Accept Video' : 'Accept',
                      icon: isVideo ? Icons.videocam : Icons.call,
                      color: AppColors.whatsappEmerald,
                      onPressed: _handling ? null : _accept,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IncomingActionButton extends StatelessWidget {
  const _IncomingActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, color: Colors.white, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
