import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/database/app_database.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/connection_banner.dart';
import '../../shared/widgets/app_widgets.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_search_picker.dart';
import '../calls/call_controller.dart';
import '../chat/media_message.dart';
import '../presence/presence_controller.dart';

/// The conversation list, styled after the Stitch "Chats" screen:
/// a `surface-container-low` app bar, `list-two-line` rows on hairline
/// dividers, an emerald new-chat FAB and the pill-indicator bottom bar.
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  final _searchController = TextEditingController();
  _ChatFilter _filter = _ChatFilter.all;
  String _query = '';
  bool _refreshing = false;
  bool _freshPromptOpen = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value.trim().toLowerCase());
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
  }

  /// Applies the active filter chip and search query, matching the Stitch
  /// "Chats" logic: a row is visible when its type matches AND its text
  /// (title + preview) contains the query.
  List<LocalConversation> _applyFilters(List<LocalConversation> items) {
    return items.where((conversation) {
      final typeMatch = switch (_filter) {
        _ChatFilter.all => true,
        _ChatFilter.personal => conversation.type == 'direct',
        _ChatFilter.group => conversation.type == 'group',
      };
      if (!typeMatch) return false;
      if (_query.isEmpty) return true;
      final haystack =
          '${_conversationTitle(conversation)} ${conversation.lastMessagePreview ?? ''}'
              .toLowerCase();
      return haystack.contains(_query);
    }).toList();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final api = ref.read(apiClientProvider);
      final conversations = await api.conversations(limit: 100);
      await ref.read(chatDaoProvider).upsertConversations(
            conversations,
            selfId: ref.read(currentUserProvider)?.id,
          );
      await ref.read(chatSocketProvider).syncAll(selfId: ref.read(currentUserProvider)?.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not refresh: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _startNewChat() async {
    final choice = await showModalBottomSheet<_ComposeChoice>(
      context: context,
      builder: (_) => const _ComposeSheet(),
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case _ComposeChoice.direct:
        await _startDirectChat();
      case _ComposeChoice.group:
        if (mounted) context.push('/conversations/new-group');
    }
  }

  Future<void> _startDirectChat() async {
    final picked = await showUserSearchSheet(context);
    if (picked.isEmpty || !mounted) return;
    final userId = picked.first.id;

    try {
      final conversation = await ref.read(apiClientProvider).createDirectConversation(userId);
      await ref.read(chatDaoProvider).upsertConversation(
            conversation,
            selfId: ref.read(currentUserProvider)?.id,
          );
      if (mounted) context.push('/conversations/${conversation.id}');
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _showFreshPartitionPrompt() async {
    if (_freshPromptOpen || !mounted) return;
    _freshPromptOpen = true;
    var startFresh = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Start fresh on this device?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Encrypted history is not restored on a new or cleared device. '
                  'Choose what to do with your group chat history:',
                ),
                const SizedBox(height: AppSpacing.md),
                RadioGroup<bool>(
                  groupValue: startFresh,
                  onChanged: (value) =>
                      setDialogState(() => startFresh = value ?? true),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<bool>(
                        contentPadding: EdgeInsets.zero,
                        value: true,
                        title: Text('Start fresh'),
                        subtitle: Text('Clear group chat history too'),
                      ),
                      RadioListTile<bool>(
                        contentPadding: EdgeInsets.zero,
                        value: false,
                        title: Text('Keep group history'),
                        subtitle: Text('Restore existing plaintext group chats'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      );
      ref.read(freshPartitionPromptProvider.notifier).dismiss();
      if (confirmed == true && startFresh && mounted) {
        final scope = ref.read(accountScopeProvider);
        if (scope != null) {
          await ref.read(accountWiperProvider).clearAllChats(
                accountId: scope.accountId,
                dao: ref.read(chatDaoProvider),
                api: ref.read(apiClientProvider),
                mediaCache: ref.read(mediaCacheProvider),
              );
        }
      }
    } finally {
      _freshPromptOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final user = ref.watch(currentUserProvider);

    ref.listen<bool>(freshPartitionPromptProvider, (previous, next) {
      if (next && !(previous ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showFreshPartitionPrompt();
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('CP Chat'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md, left: AppSpacing.xs),
            child: IconButton(
              tooltip: 'My profile',
              icon: UserAvatarWithStatus(
                avatarKey: user?.avatarUrl,
                name: user?.name ?? '?',
                status: user?.effectiveStatus,
                radius: 18,
                showStatus: false,
              ),
              onPressed: () => context.go('/profile'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: user == null
                ? const Center(child: CircularProgressIndicator())
                : conversations.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (error, _) => EmptyState(
                      icon: Icons.error_outline,
                      title: 'Something went wrong',
                      message: '$error',
                      action: FilledButton.tonal(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ),
                    data: (items) {
                      final visible = _applyFilters(items);
                      return Column(
                        children: [
                          _ChatListHeader(
                            controller: _searchController,
                            filter: _filter,
                            onQueryChanged: _onSearchChanged,
                            onClear: _clearSearch,
                            onFilterChanged: (filter) =>
                                setState(() => _filter = filter),
                          ),
                          Expanded(
                            child: _buildConversationList(items, visible, user.id),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _refreshing ? null : _startNewChat,
        tooltip: 'New chat',
        child: const Icon(Icons.add_comment_outlined),
      ),
    );
  }

  Widget _buildConversationList(
    List<LocalConversation> items,
    List<LocalConversation> visible,
    String selfId,
  ) {
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            EmptyState(
              icon: Icons.forum_outlined,
              title: 'No conversations yet',
              message: 'Start a 1:1 chat or create a group to get going.',
              action: FilledButton.icon(
                onPressed: _startNewChat,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('New chat'),
              ),
            ),
          ],
        ),
      );
    }

    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            EmptyState(
              icon: Icons.search_off,
              title: 'No chats found',
              message: 'Try a different search or filter.',
            ),
          ],
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: visible.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          indent: AppSpacing.lg,
          endIndent: AppSpacing.lg,
          color: scheme.outlineVariant,
        ),
        itemBuilder: (context, index) {
          final conversation = visible[index];
          return _ConversationTile(
            conversation: conversation,
            selfId: selfId,
            onTap: () => context.push('/conversations/${conversation.id}'),
          );
        },
      ),
    );
  }
}

/// Display title for a conversation row: the group name, or `Name (nickname)`
/// for a direct chat. Shared by the list tile and the search filter so both
/// agree on the text a query matches against.
String _conversationTitle(LocalConversation conversation) {
  if (conversation.type == 'group') return conversation.name ?? 'Group';
  final name = conversation.peerName ?? conversation.name ?? 'Chat';
  final nickname = conversation.peerNickname?.trim();
  if (nickname == null || nickname.isEmpty) return name;
  return '$name ($nickname)';
}

/// Chats filter chips from the Stitch "Chats" screen.
enum _ChatFilter {
  all('All'),
  personal('Personal'),
  group('Groups');

  const _ChatFilter(this.label);

  final String label;
}

/// The pill search bar plus the All / Personal / Groups filter chips that sit
/// above the chat list, ported from the Stitch "Chats" screen.
class _ChatListHeader extends StatelessWidget {
  const _ChatListHeader({
    required this.controller,
    required this.filter,
    required this.onQueryChanged,
    required this.onClear,
    required this.onFilterChanged,
  });

  final TextEditingController controller;
  final _ChatFilter filter;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClear;
  final ValueChanged<_ChatFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.md,
        AppSpacing.pageMargin,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SearchField(
            controller: controller,
            hintText: 'Search chats...',
            onChanged: onQueryChanged,
            onClear: onClear,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              for (final option in _ChatFilter.values)
                _ChatFilterChip(
                  label: option.label,
                  selected: option == filter,
                  onSelected: () => onFilterChanged(option),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A pill filter chip: the active chip uses the secondary container colour,
/// inactive chips use the high surface container, per the design system.
class _ChatFilterChip extends StatelessWidget {
  const _ChatFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelected,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// One `list-two-line` row: avatar, title + timestamp, preview + unread badge.
class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selfId,
    required this.onTap,
  });

  final LocalConversation conversation;
  final String selfId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isGroup = conversation.type == 'group';
    final title = _conversationTitle(conversation);
    final unread = conversation.unreadCount;

    // A direct chat shows the peer's live presence dot; a group has no single
    // presence, so it keeps the group icon.
    final presence = isGroup || conversation.peerId == null
        ? null
        : ref.watch(presenceProvider(conversation.peerId!));
    final activeGroupCall =
        isGroup ? ref.watch(activeGroupCallsProvider)[conversation.id] : null;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            isGroup
                ? _GroupAvatar(avatarKey: conversation.avatarUrl)
                : UserAvatarWithStatus(
                    avatarKey: conversation.peerAvatarUrl,
                    name: conversation.peerName ?? title,
                    status: presence?.resolvedStatus,
                    radius: 24,
                  ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        _relativeTime(conversation.updatedAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (activeGroupCall != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.whatsappEmerald.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.call,
                                size: 12,
                                color: AppColors.whatsappEmerald,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'In call',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.whatsappEmerald,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (unread > 0) ...[
                        const SizedBox(width: AppSpacing.sm),
                        _UnreadBadge(count: unread),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    final preview = conversation.lastMessagePreview;
    return preview ?? 'No messages yet';
  }

  String _relativeTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);
    if (difference.inMinutes < 1) return 'now';
    if (difference.inHours < 1) return '${difference.inMinutes}m';
    if (difference.inDays < 1) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    if (difference.inDays < 7) return '${difference.inDays}d';
    return '${local.day}/${local.month}';
  }
}

/// Group avatars use `surface-container-highest` with a muted group glyph.
class _GroupAvatar extends ConsumerWidget {
  const _GroupAvatar({required this.avatarKey});

  final String? avatarKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.group, color: scheme.onSurfaceVariant);

    if (avatarKey == null) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: fallback,
      );
    }
    return MediaAvatar(objectKey: avatarKey, radius: 24, fallback: fallback);
  }
}

/// Emerald unread counter from the design system's primary accent.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

enum _ComposeChoice { direct, group }

/// Lets the user choose between starting a 1:1 chat and creating a group.
class _ComposeSheet extends StatelessWidget {
  const _ComposeSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('New chat', style: theme.textTheme.titleLarge),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Direct message'),
            subtitle: const Text('Message one person'),
            onTap: () => Navigator.of(context).pop(_ComposeChoice.direct),
          ),
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('New group'),
            subtitle: const Text('Up to 500 members'),
            onTap: () => Navigator.of(context).pop(_ComposeChoice.group),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}
