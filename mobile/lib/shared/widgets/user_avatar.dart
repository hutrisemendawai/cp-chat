import 'package:material_ui/material_ui.dart';

import '../../features/chat/media_message.dart';
import 'status_badge.dart';

/// An avatar with a Discord-style presence dot in the bottom-right corner.
///
/// Works with data already available locally (cached peer name/avatar and a
/// live [Presence]) so the chat list renders without a network round trip. When
/// [avatarKey] is null the avatar falls back to the first letter of [name].
class UserAvatarWithStatus extends StatelessWidget {
  const UserAvatarWithStatus({
    super.key,
    this.avatarKey,
    required this.name,
    this.status,
    this.radius = 20,
    this.showStatus = true,
  });

  final String? avatarKey;
  final String name;

  /// `online` | `idle` | `dnd` | `offline` | `invisible`.
  final String? status;
  final double radius;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

    final avatar = MediaAvatar(
      objectKey: avatarKey,
      radius: radius,
      fallback: Text(
        initial,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );

    if (!showStatus) return avatar;

    final dotSize = radius * 0.75;
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: StatusBadge(
              status: status,
              size: dotSize,
              borderColor: theme.colorScheme.surface,
            ),
          ),
        ],
      ),
    );
  }
}
