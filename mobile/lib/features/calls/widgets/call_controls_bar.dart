import 'package:material_ui/material_ui.dart';

import '../../../core/models/call_models.dart';
import '../../../core/theme/app_colors.dart';

/// Bottom call control bar shared by 1-on-1 and Group active call screens.
class CallControlsBar extends StatelessWidget {
  const CallControlsBar({
    super.key,
    required this.audioMuted,
    required this.videoEnabled,
    required this.audioRoute,
    required this.availableAudioRoutes,
    required this.isGroup,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onFlipCamera,
    required this.onSelectAudioRoute,
    required this.onHangUp,
    this.onShowParticipants,
  });

  final bool audioMuted;
  final bool videoEnabled;
  final AudioRoute audioRoute;
  final List<AudioRoute> availableAudioRoutes;
  final bool isGroup;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onFlipCamera;
  final ValueChanged<AudioRoute> onSelectAudioRoute;
  final VoidCallback onHangUp;
  final VoidCallback? onShowParticipants;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ControlButton(
            tooltip: audioMuted ? 'Unmute' : 'Mute',
            icon: audioMuted ? Icons.mic_off : Icons.mic,
            active: audioMuted,
            onPressed: onToggleMute,
          ),
          const SizedBox(width: 12),
          _ControlButton(
            tooltip: videoEnabled ? 'Turn camera off' : 'Turn camera on',
            icon: videoEnabled ? Icons.videocam : Icons.videocam_off,
            active: videoEnabled,
            activeColor: AppColors.whatsappEmerald,
            onPressed: onToggleCamera,
          ),
          if (videoEnabled) ...[
            const SizedBox(width: 12),
            _ControlButton(
              tooltip: 'Switch camera',
              icon: Icons.cameraswitch,
              onPressed: onFlipCamera,
            ),
          ],
          const SizedBox(width: 12),
          _ControlButton(
            tooltip: _audioTooltip(audioRoute),
            icon: _audioIcon(audioRoute),
            active: audioRoute != AudioRoute.earpiece,
            onPressed: () => _pickAudioRoute(context),
          ),
          if (isGroup && onShowParticipants != null) ...[
            const SizedBox(width: 12),
            _ControlButton(
              tooltip: 'Participants',
              icon: Icons.people_outline,
              onPressed: onShowParticipants!,
            ),
          ],
          const SizedBox(width: 12),
          _ControlButton(
            tooltip: 'Hang up',
            icon: Icons.call_end,
            backgroundColor: Colors.red.shade600,
            foregroundColor: Colors.white,
            onPressed: onHangUp,
          ),
        ],
      ),
    );
  }

  void _pickAudioRoute(BuildContext context) {
    if (availableAudioRoutes.length <= 2) {
      final next = audioRoute == AudioRoute.speaker
          ? AudioRoute.earpiece
          : AudioRoute.speaker;
      onSelectAudioRoute(next);
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Audio output',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            for (final route in availableAudioRoutes)
              ListTile(
                leading: Icon(_audioIcon(route)),
                title: Text(_audioLabel(route)),
                trailing: route == audioRoute
                    ? const Icon(Icons.check, color: AppColors.whatsappEmerald)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onSelectAudioRoute(route);
                },
              ),
          ],
        ),
      ),
    );
  }

  static IconData _audioIcon(AudioRoute route) => switch (route) {
        AudioRoute.earpiece => Icons.phone_in_talk,
        AudioRoute.speaker => Icons.volume_up,
        AudioRoute.bluetooth => Icons.bluetooth_audio,
      };

  static String _audioLabel(AudioRoute route) => switch (route) {
        AudioRoute.earpiece => 'Phone earpiece',
        AudioRoute.speaker => 'Speaker',
        AudioRoute.bluetooth => 'Bluetooth headset',
      };

  static String _audioTooltip(AudioRoute route) => 'Audio: ${_audioLabel(route)}';
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.activeColor,
    this.backgroundColor,
    this.foregroundColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final Color? activeColor;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ??
        (active
            ? (activeColor ?? Colors.white)
            : Colors.white.withValues(alpha: 0.16));
    final fg = foregroundColor ??
        (active
            ? (activeColor != null ? Colors.white : Colors.black87)
            : Colors.white);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: fg, size: 22),
          ),
        ),
      ),
    );
  }
}
