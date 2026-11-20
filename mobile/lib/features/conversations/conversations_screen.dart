import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/database/app_database.dart';
import '../../core/models/models.dart';

import '../../core/providers.dart';

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
    final userId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _NewChatSheet(),
    );
    if (userId == null || !mounted) return;

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
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/auth');
            },
          ),
        ],
      ),
      body: user == null
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
      floatingActionButton: FloatingActionButton(
        onPressed: _refreshing ? null : _startNewChat,
        tooltip: 'New chat',
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selfId,
    required this.onTap,
  });

  final LocalConversation conversation;
  final String selfId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = conversation.peerName ?? conversation.name ?? 'Chat';
    final unread = conversation.unreadCount;

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
        child: Text(
          title.isEmpty ? '?' : title.characters.first.toUpperCase(),
        ),
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

/// Looks up a user by exact phone/email or user id, then starts a direct chat.
class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet();

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  final _controller = TextEditingController();
  bool _busy = false;
  User? _found;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
      _found = null;
    });

    try {
      final api = ref.read(apiClientProvider);
      // The REST contract exposes lookup by id; an email is not resolvable
      // without a directory endpoint, so tell the user what to provide.
      final user = await api.user(query);
      if (user.id == ref.read(currentUserProvider)?.id) {
        setState(() => _error = 'That is you. Pick someone else.');
      } else {
        setState(() => _found = user);
      }
    } on ApiException catch (error) {
      setState(() => _error = error.code == 'not_found'
          ? 'No user with that id. Ask them for their user id.'
          : error.message);
    } catch (_) {
      setState(() => _error = 'Lookup failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New chat', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              enabled: !_busy,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _lookup(),
              decoration: InputDecoration(
                labelText: 'User id',
                helperText: 'Paste the user id of the person you want to chat with.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _lookup,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (_found != null) ...[
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text(_found!.name.characters.first.toUpperCase()),
                ),
                title: Text(_found!.name),
                subtitle: Text(_found!.id),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_found!.id),
                child: Text('Chat with ${_found!.name}'),
              ),
            ],
          ],
        ),
      ),
    );
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
