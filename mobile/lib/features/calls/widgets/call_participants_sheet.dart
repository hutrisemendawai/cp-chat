import 'package:livekit_client/livekit_client.dart' show ConnectionQuality;
import 'package:material_ui/material_ui.dart';

import '../../../core/models/call_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/user_avatar.dart';

/// Modal bottom sheet listing all connected participants in a group call.
class CallParticipantsSheet extends StatelessWidget {
  const CallParticipantsSheet({
    super.key,
    required this.participants,
  });

  final List<CallParticipantView> participants;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text(
                    'In this call (${participants.length})',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: participants.length,
                itemBuilder: (context, index) {
                  final p = participants[index];
                  return ListTile(
                    leading: UserAvatarWithStatus(
                      avatarKey: p.avatarUrl,
                      name: p.displayName,
                      radius: 20,
                      showStatus: false,
                    ),
                    title: Text(
                      p.isLocal ? '${p.displayName} (You)' : p.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: p.isSpeaking
                        ? const Text(
                            'Speaking',
                            style: TextStyle(color: AppColors.whatsappEmerald),
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _QualityDot(quality: p.connectionQuality),
                        const SizedBox(width: 10),
                        Icon(
                          p.audioMuted ? Icons.mic_off : Icons.mic,
                          size: 18,
                          color: p.audioMuted
                              ? Colors.redAccent
                              : AppColors.whatsappEmerald,
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          p.videoEnabled ? Icons.videocam : Icons.videocam_off,
                          size: 18,
                          color: p.videoEnabled
                              ? AppColors.whatsappEmerald
                              : Colors.grey,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QualityDot extends StatelessWidget {
  const _QualityDot({required this.quality});

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
