import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/direct_chat.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/user_avatar.dart';
import '../people/people_controller.dart';
import '../presence/presence_controller.dart';

/// A Discord-inspired public profile for any user, with a one-tap direct chat
/// and friend toggle. Opened from People results, chat headers and group info.
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
    final profile = ref.watch(userProfileProvider(widget.userId));
    final presence = ref.watch(presenceProvider(widget.userId));
    final selfId = ref.watch(currentUserProvider)?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: '$error',
          onRetry: () => ref.invalidate(userProfileProvider(widget.userId)),
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

          return ListView(
            padding: EdgeInsets.zero,
            children: [
              _header(context, user, snapshot.resolvedStatus),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Column(
                  children: [
                    _title(theme, user),
                    const SizedBox(height: 10),
                    _statusRow(theme, snapshot),
                    if (snapshot.customStatus?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 10),
                      _customStatusBubble(theme, snapshot.customStatus!.trim()),
                    ],
                    if (!isSelf) ...[
                      const SizedBox(height: 24),
                      _actions(context, user, isFriend),
                    ] else ...[
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: () => context.go('/profile'),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit Profile'),
                        ),
                      ),
                    ],
                    if (user.phoneOrEmail != null) ...[
                      const SizedBox(height: 24),
                      _card(
                        theme,
                        icon: Icons.alternate_email,
                        label: 'Contact',
                        child: Text(user.phoneOrEmail!),
                      ),
                    ],
                    if (user.bio?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 12),
                      _card(
                        theme,
                        icon: Icons.notes_outlined,
                        label: 'Bio',
                        child: Text(user.bio!.trim()),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, User user, String status) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 180,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary,
                    theme.colorScheme.primaryContainer,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 62,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () => _previewAvatar(context, user),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    shape: BoxShape.circle,
                  ),
                  child: UserAvatarWithStatus(
                    avatarKey: user.avatarUrl,
                    name: user.displayName,
                    status: status,
                    radius: 44,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(ThemeData theme, User user) {
    return Text(
      user.displayName,
      textAlign: TextAlign.center,
      style: theme.textTheme.headlineSmall,
    );
  }

  Widget _statusRow(ThemeData theme, Presence snapshot) {
    final status = snapshot.resolvedStatus;
    final label = snapshot.isActive
        ? statusLabel(status)
        : (formatPresence(snapshot) ?? 'Offline');

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        StatusBadge(status: status, size: 14),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: snapshot.isActive
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _customStatusBubble(ThemeData theme, String customStatus) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(customStatus, textAlign: TextAlign.center),
    );
  }

  Widget _actions(BuildContext context, User user, bool isFriend) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _busy ? null : () => openDirectChat(context, ref, user),
            icon: const Icon(Icons.chat),
            label: const Text('Message'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _toggleFriend(user, isFriend),
            icon: Icon(isFriend ? Icons.person_remove_outlined : Icons.person_add_alt_1),
            label: Text(isFriend ? 'Remove Friend' : 'Add Friend'),
          ),
        ),
      ],
    );
  }

  Widget _card(ThemeData theme, {
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  child,
                ],
              ),
            ),
          ],
        ),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
