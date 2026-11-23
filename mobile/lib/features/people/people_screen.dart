import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../shared/widgets/direct_chat.dart';
import '../../shared/widgets/user_avatar.dart';
import '../presence/presence_controller.dart';
import 'people_controller.dart';

/// The user directory: a debounced name/email search plus the friends list.
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
    final controller = TextEditingController();
    final identifier = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add friend'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Email, phone or name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();

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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search users by name or email...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.clear),
                        onPressed: _clear,
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
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
    final theme = Theme.of(context);

    return friends.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ListView(
        children: [
          _Hint(
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
                _Hint(
                  icon: Icons.group_outlined,
                  title: 'No friends yet',
                  message: 'Find people by name or email, then add them.',
                  action: FilledButton.icon(
                    onPressed: onAddFriend,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Add Friend by Email / Name'),
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
            itemCount: users.length + 1,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Friends',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              final user = users[index - 1];
              return _UserTile(
                user: user,
                onTap: () => context.push('/users/${user.id}'),
                trailing: IconButton(
                  tooltip: 'Chat',
                  icon: const Icon(Icons.chat_bubble_outline),
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
    final theme = Theme.of(context);

    if (state.loading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.results.isEmpty) {
      return _Hint(
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
      return _Hint(
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
            itemCount: state.results.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final user = state.results[index];
              return _UserTile(
                user: user,
                onTap: () => context.push('/users/${user.id}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Chat',
                      icon: const Icon(Icons.chat_bubble_outline),
                      onPressed: () => openDirectChat(context, ref, user),
                    ),
                    IconButton(
                      tooltip: user.isFriend ? 'Remove friend' : 'Add friend',
                      icon: Icon(
                        user.isFriend
                            ? Icons.how_to_reg
                            : Icons.person_add_alt_1_outlined,
                        color: user.isFriend ? theme.colorScheme.primary : null,
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

/// A person row: live presence dot, `Name (nickname)` title and a custom status
/// or contact line. The avatar and title both open the full profile.
class _UserTile extends ConsumerWidget {
  const _UserTile({required this.user, required this.onTap, this.trailing});

  final User user;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(presenceProvider(user.id));
    final status = presence?.resolvedStatus ?? user.effectiveStatus;
    final custom = user.customStatus?.trim();
    final subtitle = custom != null && custom.isNotEmpty
        ? custom
        : (user.phoneOrEmail ?? '');

    return ListTile(
      onTap: onTap,
      leading: UserAvatarWithStatus(
        avatarKey: user.avatarUrl,
        name: user.displayName,
        status: status,
      ),
      title: Text(user.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          if (action != null) ...[
            const SizedBox(height: 20),
            action!,
          ],
        ],
      ),
    );
  }
}

