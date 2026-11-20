import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import 'chat_controller.dart';
import 'conversation_metadata.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _composer = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;

  @override
  void initState() {
    super.initState();
    _composer.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _onOpen());
  }

  @override
  void dispose() {
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onOpen() async {
    final controller = ref.read(chatControllerProvider(widget.conversationId));
    // Catch up on anything missed, then mark the newest message read.
    await ref.read(chatSocketProvider).syncAll(selfId: ref.read(currentUserProvider)?.id);
    await controller.markRead();
    await _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _composer.clear();
    try {
      await ref.read(chatControllerProvider(widget.conversationId)).sendText(text);
      await _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreHistory) return;
    setState(() => _loadingOlder = true);
    try {
      final hasMore = await ref
          .read(chatControllerProvider(widget.conversationId))
          .loadOlder();
      if (mounted) setState(() => _hasMoreHistory = hasMore);
    } catch (_) {
      if (mounted) setState(() => _hasMoreHistory = false);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _scrollToBottom() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selfId = ref.watch(currentUserProvider)?.id;
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final conversation = ref.watch(conversationLocalProvider(widget.conversationId));
    final metadata = ref.watch(conversationMetadataProvider(widget.conversationId));

    final cached = conversation.value;
    final title = cached?.peerName ??
        cached?.name ??
        metadata.value?.displayName(selfId ?? '') ??
        'Chat';

    ref.listen(messagesProvider(widget.conversationId), (_, _) {
      // Incoming messages while the screen is open are read immediately.
      unawaited(ref.read(chatControllerProvider(widget.conversationId)).markRead());
    });

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('Could not load messages: $error')),
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'Say hello 👋',
                      style: theme.textTheme.bodyLarge,
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                  itemCount: items.length + (_hasMoreHistory ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_hasMoreHistory && index == 0) {
                      return Center(
                        child: TextButton(
                          onPressed: _loadingOlder ? null : _loadOlder,
                          child: Text(_loadingOlder ? 'Loading…' : 'Load earlier messages'),
                        ),
                      );
                    }
                    final message = items[index - (_hasMoreHistory ? 1 : 0)];
                    return _MessageBubble(
                      message: message,
                      isMine: message.senderId == selfId,
                      onRetry: () => ref
                          .read(chatControllerProvider(widget.conversationId))
                          .retry(message.clientMsgId),
                      onDiscard: () => ref
                          .read(chatControllerProvider(widget.conversationId))
                          .discard(message.clientMsgId),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _composer.text.trim().isEmpty || _sending ? null : _send,
                    tooltip: 'Send',
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live local row for the header, so the peer name appears without a round trip.
final conversationLocalProvider =
    StreamProvider.family<LocalConversation?, String>((ref, conversationId) {
  return ref.watch(chatDaoProvider).watchConversation(conversationId);
});

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.onRetry,
    required this.onDiscard,
  });

  final LocalMessage message;
  final bool isMine;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  bool get _failed => message.status == 'failed';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final background = isMine
        ? (_failed ? scheme.errorContainer : scheme.primaryContainer)
        : scheme.surfaceContainerHighest;
    final foreground = isMine
        ? (_failed ? scheme.onErrorContainer : scheme.onPrimaryContainer)
        : scheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onLongPress: isMine ? () => _showActions(context) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        message.content,
                        style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _time(message.createdAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.7),
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          _StatusIcon(status: message.status, color: foreground),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_failed)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Retry'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onRetry();
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onDiscard();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip) = switch (status) {
      'pending' => (Icons.schedule, 'Sending'),
      'sent' => (Icons.check, 'Sent'),
      'delivered' => (Icons.done_all, 'Delivered'),
      'read' => (Icons.done_all, 'Read'),
      'failed' => (Icons.error_outline, 'Failed to send'),
      _ => (Icons.schedule, 'Sending'),
    };

    return Tooltip(
      message: tooltip,
      child: Icon(
        icon,
        size: 14,
        color: status == 'read' ? const Color(0xFF2563EB) : color.withValues(alpha: 0.7),
      ),
    );
  }
}
