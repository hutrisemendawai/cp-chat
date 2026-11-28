import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/models/call_models.dart';
import '../../../core/theme/app_colors.dart';
import '../call_controller.dart';

/// Compact banner rendered inside a group `ChatScreen` right below
/// `ConnectionBanner` whenever the group has an ongoing call the user is not
/// currently participating in.
class GroupActiveCallBanner extends StatelessWidget {
  const GroupActiveCallBanner({
    super.key,
    required this.summary,
    required this.onJoin,
  });

  final ActiveCallSummary summary;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final count = summary.participantCount;
    final kind = summary.isVideo ? 'video' : 'voice';
    final subtitle = count > 0
        ? 'Ongoing $kind call · $count in call'
        : 'Ongoing $kind call';

    return Material(
      color: AppColors.whatsappEmerald.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: AppColors.whatsappEmerald,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              summary.isVideo ? Icons.videocam : Icons.call,
              size: 18,
              color: AppColors.whatsappEmerald,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.whatsappEmerald,
                    ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onJoin,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.whatsappEmerald,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top return-to-call bar shown globally when the user minimizes an active call
/// to browse chats or send a message.
class OngoingCallReturnBar extends ConsumerWidget {
  const OngoingCallReturnBar({
    super.key,
    required this.onReturnToCall,
  });

  final VoidCallback onReturnToCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    if (!call.isMinimized || !call.isLiveSession) {
      return const SizedBox.shrink();
    }

    final timer = formatCallDuration(call.elapsed);
    final label = call.status == CallStatus.reconnecting
        ? 'Reconnecting...'
        : call.status == CallStatus.calling
            ? 'Calling ${call.conversationTitle}...'
            : '${call.conversationTitle} · $timer';

    return Material(
      color: AppColors.whatsappEmerald,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onReturnToCall,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.call, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Text(
                  'Tap to return',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String formatCallDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
