import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../features/chat/media_message.dart';
import 'status_badge.dart';

/// An avatar with a presence dot in the bottom-right corner.
///
/// Works with data already available locally (cached peer name/avatar and a
/// live presence) so the chat list renders without a network round trip. When
/// [avatarKey] is null the avatar falls back to the first letter of [name] on
/// the design system's `secondary-container` background.
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
    final scheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();

    final fallback = Text(
      initial,
      style: TextStyle(
        fontFamily: AppTypography.display,
        fontSize: radius * 0.8,
        fontWeight: FontWeight.w600,
        color: scheme.onSecondaryContainer,
      ),
    );

    final avatar = avatarKey == null
        ? _InitialsCircle(radius: radius, child: fallback)
        : MediaAvatar(objectKey: avatarKey, radius: radius, fallback: fallback);

    if (!showStatus) return avatar;

    // Matches the design system's 3.5px dot on a 48px avatar.
    final dotSize = radius * 0.58;
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
              borderColor: scheme.surface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Initials fallback drawn on the design system's `secondary-container` tone.
class _InitialsCircle extends StatelessWidget {
  const _InitialsCircle({required this.radius, required this.child});

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
