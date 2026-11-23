import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_widgets.dart';
import '../../shared/widgets/direct_chat.dart';
import '../../shared/widgets/user_avatar.dart';
import '../presence/presence_controller.dart';
import 'people_controller.dart';

/// The user directory, styled after the Stitch "People" screen: a muted
/// rounded search field, an emerald `Friends` section label and two-line rows
/// with a trailing chat action.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() {});
    ref.read(peopleControllerProvider.notifier).updateQuery(value);
  }

  void _clear() {
    _search.clear();
    setState(() {});
    ref.read(peopleControllerProvider.notifier).clear();
  }

  Future<void> _addFriendByIdentifier() async {
    final identifier = await showDialog<String>(
      context: context,
      builder: (_) => const _AddFriendDialog(),
    );

    if (identifier == null || identifier.isEmpty || !mounted) return;
    final error = await ref
        .read(peopleControllerProvider.notifier)
        .addFriendByIdentifier(identifier);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Friend added')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(peopleControllerProvider);
    final friends = ref.watch(friendsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        actions: [
          IconButton(
            tooltip: 'Add friend',
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: _addFriendByIdentifier,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.md,
              AppSpacing.pageMargin,
              AppSpacing.sm,
            ),
            child: SearchField(
              controller: _search,
              hintText: 'Search users by name or email...',
              onChanged: _onQueryChanged,
              onClear: _clear,
            ),
          ),
          Expanded(
            child: state.isSearching
                ? _SearchResults(state: state)
                : _FriendsList(
                    friends: friends,
                    onAddFriend: _addFriendByIdentifier,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Owns its text controller for the lifetime of the route: disposing it as soon
/// as `showDialog` resolves would run while the dialog is still animating out.
class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog();

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add friend'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Email, phone or name',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

class _FriendsList extends ConsumerWidget {
  const _FriendsList({required this.friends, required this.onAddFriend});

  final AsyncValue<List<User>> friends;
  final VoidCallback onAddFriend;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(friendsProvider);
    await ref.read(friendsProvider.future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return friends.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ListView(
        children: [
          EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load friends',
            message: '$error',
            action: FilledButton.tonal(
              onPressed: () => ref.invalidate(friendsProvider),
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
      data: (users) {
        if (users.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => _refresh(ref),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                EmptyState(
                  icon: Icons.group_outlined,
                  title: 'No friends yet',
                  message: 'Find people by name or email, then add them.',
                  action: FilledButton.icon(
                    onPressed: onAddFriend,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Add friend'),
                  ),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () => _refresh(ref),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: AppSpacing.section),
            itemCount: users.length + 1,
            separatorBuilder: (_, index) => index == 0
                ? const SizedBox.shrink()
                : Divider(
                    height: 1,
                    indent: AppSpacing.lg,
                    endIndent: AppSpacing.lg,
                    color: scheme.outlineVariant,
                  ),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: SectionLabel(
                    text: 'Friends',
                    emphasized: true,
                    trailing: Text(
                      '${users.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                  ),
                );
              }
              final user = users[index - 1];
              return _UserTile(
                user: user,
                onTap: () => context.push('/users/${user.id}'),
                trailing: IconButton(
                  tooltip: 'Message',
                  icon: const Icon(Icons.chat_bubble_outline),
                  color: scheme.primary,
                  onPressed: () => openDirectChat(context, ref, user),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.state});

  final PeopleState state;

  Future<void> _toggleFriend(BuildContext context, WidgetRef ref, User user) async {
    final error = await ref.read(peopleControllerProvider.notifier).toggleFriend(user);
    if (!context.mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    if (state.loading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.results.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Search failed',
        message: state.error!,
        action: FilledButton.tonal(
          onPressed: () => ref
              .read(peopleControllerProvider.notifier)
              .updateQuery(state.query),
          child: const Text('Retry'),
        ),
      );
    }
    if (state.results.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_outlined,
        title: 'No matches',
        message: 'No one matches "${state.query.trim()}".',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: AppSpacing.section),
            itemCount: state.results.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              indent: AppSpacing.lg,
              endIndent: AppSpacing.lg,
              color: scheme.outlineVariant,
            ),
            itemBuilder: (context, index) {
              final user = state.results[index];
              return _UserTile(
                user: user,
                onTap: () => context.push('/users/${user.id}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Message',
                      icon: const Icon(Icons.chat_bubble_outline),
                      color: scheme.primary,
                      onPressed: () => openDirectChat(context, ref, user),
                    ),
                    IconButton(
                      tooltip: user.isFriend ? 'Remove friend' : 'Add friend',
                      icon: Icon(
                        user.isFriend
                            ? Icons.how_to_reg
                            : Icons.person_add_alt_1_outlined,
                        color: user.isFriend ? scheme.primary : null,
                      ),
                      onPressed: () => _toggleFriend(context, ref, user),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A person row: presence dot, `Name (nickname)` title and a custom status or
/// contact line. The avatar and title both open the full profile.
class _UserTile extends ConsumerWidget {
  const _UserTile({required this.user, required this.onTap, this.trailing});

  final User user;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final presence = ref.watch(presenceProvider(user.id));
    final status = presence?.resolvedStatus ?? user.effectiveStatus;
    final custom = user.customStatus?.trim();
    final subtitle = custom != null && custom.isNotEmpty
        ? custom
        : (user.phoneOrEmail ?? '');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            UserAvatarWithStatus(
              avatarKey: user.avatarUrl,
              name: user.displayName,
              status: status,
              radius: 24,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
