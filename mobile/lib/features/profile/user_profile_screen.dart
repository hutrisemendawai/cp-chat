import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_widgets.dart';
import '../../shared/widgets/direct_chat.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/user_avatar.dart';
import '../people/people_controller.dart';
import '../presence/presence_controller.dart';

/// Another user's profile, styled after the Stitch "Contact Profile" screen:
/// a compact centred identity block (no tall banner), a Message button beside
/// an outlined remove-friend action, and a grouped contact/bio card.
class UserProfileScreen extends ConsumerStatefulWidget {
  const UserProfileScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  /// Optimistic friendship state while a toggle request is in flight.
  bool? _friendOverride;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = ref.watch(userProfileProvider(widget.userId));
    final presence = ref.watch(presenceProvider(widget.userId));
    final selfId = ref.watch(currentUserProvider)?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load profile',
          message: '$error',
          action: FilledButton.tonal(
            onPressed: () => ref.invalidate(userProfileProvider(widget.userId)),
            child: const Text('Retry'),
          ),
        ),
        data: (user) {
          final snapshot = presence ??
              Presence(
                userId: user.id,
                online: user.effectiveStatus != 'offline' &&
                    user.effectiveStatus != 'invisible' &&
                    user.effectiveStatus != null,
                status: user.effectiveStatus ?? 'offline',
                customStatus: user.customStatus,
                lastSeenAt: user.lastSeenAt,
              );
          final isSelf = selfId == user.id;
          final isFriend = _friendOverride ?? user.isFriend;
          final customStatus = snapshot.customStatus?.trim();
          final bio = user.bio?.trim();

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.lg,
              AppSpacing.pageMargin,
              AppSpacing.section,
            ),
            children: [
              // Compact identity block.
              Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () => _previewAvatar(context, user),
                      child: UserAvatarWithStatus(
                        avatarKey: user.avatarUrl,
                        name: user.displayName,
                        status: snapshot.resolvedStatus,
                        radius: 32,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      user.displayName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        StatusBadge(
                          status: snapshot.resolvedStatus,
                          size: 8,
                          borderColor: Colors.transparent,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Flexible(
                          child: Text(
                            formatPresence(snapshot) ?? 'Offline',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (customStatus != null && customStatus.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                        ),
                        child: Text(
                          customStatus,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Action row: emerald Message pill plus a destructive outline.
              if (isSelf)
                FilledButton.tonalIcon(
                  onPressed: () => context.go('/profile'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit profile'),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.primaryContainer,
                          foregroundColor: scheme.onPrimaryContainer,
                        ),
                        onPressed: _busy ? null : () => openDirectChat(context, ref, user),
                        icon: const Icon(Icons.chat, size: 18),
                        label: const Text('Message'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          foregroundColor: isFriend ? scheme.error : scheme.primary,
                          side: BorderSide(color: scheme.outlineVariant),
                          shape: const CircleBorder(),
                        ),
                        onPressed: _busy ? null : () => _toggleFriend(user, isFriend),
                        child: Icon(
                          isFriend ? Icons.person_remove : Icons.person_add_alt_1,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),

              // Grouped username + bio details card, deliberately without the
              // email address.
              if (user.username != null || (bio != null && bio.isNotEmpty)) ...[
                const SizedBox(height: AppSpacing.lg),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      if (user.username != null)
                        _DetailRow(
                          icon: Icons.alternate_email,
                          label: 'Username',
                          value: '@${user.username}',
                        ),
                      if (user.username != null &&
                          bio != null &&
                          bio.isNotEmpty)
                        Divider(height: 1, color: scheme.outlineVariant),
                      if (bio != null && bio.isNotEmpty)
                        _DetailRow(
                          icon: Icons.notes,
                          label: 'Bio',
                          value: bio,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _toggleFriend(User user, bool isFriend) async {
    final previous = isFriend;
    setState(() {
      _friendOverride = !previous;
      _busy = true;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = ref.read(apiClientProvider);
      if (previous) {
        await api.removeFriend(user.id);
      } else {
        await api.addFriend(userId: user.id);
      }
      ref.invalidate(userProfileProvider(widget.userId));
      ref.invalidate(friendsProvider);
    } catch (error) {
      if (mounted) setState(() => _friendOverride = previous);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is ApiException ? error.message : 'Could not update friend',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _previewAvatar(BuildContext context, User user) {
    if (user.avatarUrl == null) return;
    final radius = MediaQuery.sizeOf(context).shortestSide * 0.38;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => GestureDetector(
        onTap: () => Navigator.of(dialogContext).pop(),
        child: Center(
          child: InteractiveViewer(
            child: UserAvatarWithStatus(
              avatarKey: user.avatarUrl,
              name: user.displayName,
              radius: radius,
              showStatus: false,
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled detail row inside the grouped card.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
