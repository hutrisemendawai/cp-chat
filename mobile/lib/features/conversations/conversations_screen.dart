import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/database/app_database.dart';
import '../../core/models/models.dart';

import '../../core/providers.dart';
import '../../core/widgets/connection_banner.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_search_picker.dart';
import '../chat/media_message.dart';
import '../presence/presence_controller.dart';

class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  bool _refreshing = false;

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

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CP Chat'),
        actions: [
          IconButton(
            tooltip: 'Search messages',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            tooltip: 'My profile',
            icon: UserAvatarWithStatus(
              avatarKey: user?.avatarUrl,
              name: user?.name ?? '?',
              status: user?.effectiveStatus,
              radius: 14,
              showStatus: false,
            ),
            onPressed: () => context.push('/profile'),
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
                    error: (error, _) => _EmptyState(
                      icon: Icons.error_outline,
                      title: 'Something went wrong',
                      message: '$error',
                      actionLabel: 'Retry',
                      onAction: _refresh,
                    ),
                    data: (items) {
                      if (items.isEmpty) {
                        return RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            children: [
                              _EmptyState(
                                icon: Icons.forum_outlined,
                                title: 'No conversations yet',
                                message: 'Start a 1:1 chat to get going.',
                                actionLabel: 'New chat',
                                onAction: _startNewChat,
                              ),
                            ],
                          ),
                        );
                      }

                      return RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final conversation = items[index];
                            return _ConversationTile(
                              conversation: conversation,
                              selfId: user.id,
                              onTap: () => context.push('/conversations/${conversation.id}'),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _refreshing ? null : _startNewChat,
        tooltip: 'New chat',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

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
    final isGroup = conversation.type == 'group';
    final title = isGroup
        ? (conversation.name ?? 'Group')
        : _peerLabel(conversation);
    final unread = conversation.unreadCount;

    // A direct chat shows the peer's live presence dot; a group has no single
    // presence, so it keeps the group icon.
    final presence = isGroup || conversation.peerId == null
        ? null
        : ref.watch(presenceProvider(conversation.peerId!));

    return ListTile(
      onTap: onTap,
      leading: isGroup
          ? MediaAvatar(
              objectKey: conversation.avatarUrl,
              fallback: Icon(Icons.groups, color: theme.colorScheme.onPrimaryContainer),
            )
          : UserAvatarWithStatus(
              avatarKey: conversation.peerAvatarUrl,
              name: conversation.peerName ?? title,
              status: presence?.resolvedStatus,
            ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        _subtitle(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _relativeTime(conversation.updatedAt),
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 4),
          if (unread > 0)
            Badge(
              label: Text(unread > 99 ? '99+' : '$unread'),
            )
          else
            const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// "Name (nickname)" for a direct chat, matching the chat header.
  String _peerLabel(LocalConversation conversation) {
    final name = conversation.peerName ?? conversation.name ?? 'Chat';
    final nickname = conversation.peerNickname?.trim();
    if (nickname == null || nickname.isEmpty) return name;
    return '$name ($nickname)';
  }

  String _subtitle() {
    final preview = conversation.lastMessagePreview;
    if (preview == null || conversation.lastSeq == 0) return 'No messages yet';
    return preview;
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
        ],
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
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('New chat'),
            subtitle: const Text('Message one person'),
            onTap: () => Navigator.of(context).pop(_ComposeChoice.direct),
          ),
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('New group'),
            subtitle: const Text('Up to 500 members'),
            onTap: () => Navigator.of(context).pop(_ComposeChoice.group),
          ),
        ],
      ),
    );
  }
}
