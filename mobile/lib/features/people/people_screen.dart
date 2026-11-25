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
/// rounded search field that live-searches by username or email, an emerald
/// `Friends` section label and two-line rows with a trailing chat action.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(peopleControllerProvider);
    final friends = ref.watch(friendsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('People')),
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
              focusNode: _searchFocus,
              hintText: 'Search by username or email...',
              onChanged: _onQueryChanged,
              onClear: _clear,
            ),
          ),
          Expanded(
            child: !state.isSearching
                ? _FriendsList(
                    friends: friends,
                    onFindPeople: _searchFocus.requestFocus,
                  )
                : !state.isQueryLongEnough
                    ? const _SearchPrompt()
                    : _SearchResults(state: state),
          ),
        ],
      ),
    );
  }
}

/// Shown while the query is too short to search, so the network is never hit.
class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_search_outlined, size: 36, color: scheme.outline),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Type at least 3 characters to search by username or email',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsList extends ConsumerWidget {
  const _FriendsList({required this.friends, required this.onFindPeople});

  final AsyncValue<List<User>> friends;
  final VoidCallback onFindPeople;

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
                  message: 'Search by username or email to find people, then open '
                      'a profile to add them.',
                  action: FilledButton.icon(
                    onPressed: onFindPeople,
                    icon: const Icon(Icons.search),
                    label: const Text('Find people'),
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

/// Live search results: minimal avatar + name rows, with a "Load more" button
/// while the server reports another page.
class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.state});

  final PeopleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final controller = ref.read(peopleControllerProvider.notifier);

    if (state.loading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.results.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Search failed',
        message: state.error!,
        action: FilledButton.tonal(
          onPressed: () => controller.updateQuery(state.query),
          child: const Text('Retry'),
        ),
      );
    }
    if (state.results.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_outlined,
        title: 'No matching users found',
        message: 'No one matches "${state.query.trim()}".',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.section),
      itemCount: state.results.length + (state.hasMore ? 1 : 0),
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: AppSpacing.lg,
        endIndent: AppSpacing.lg,
        color: scheme.outlineVariant,
      ),
      itemBuilder: (context, index) {
        if (index >= state.results.length) {
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Center(
              child: state.loadingMore
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton.icon(
                      onPressed: controller.loadMore,
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: const Text('Load more'),
                    ),
            ),
          );
        }
        final user = state.results[index];
        return _SearchResultTile(
          user: user,
          onTap: () => context.push('/users/${user.id}'),
        );
      },
    );
  }
}

/// A minimal, profile-first search row: avatar and display name only. No email,
/// no username and no inline add button; tapping opens the full profile.
class _SearchResultTile extends ConsumerWidget {
  const _SearchResultTile({required this.user, required this.onTap});

  final User user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final presence = ref.watch(presenceProvider(user.id));
    final status = presence?.resolvedStatus ?? user.effectiveStatus;

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
              child: Text(
                user.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
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
