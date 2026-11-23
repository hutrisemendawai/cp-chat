import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/database/app_database.dart';
import '../../core/providers.dart';
import '../../core/widgets/connection_banner.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/user_avatar.dart';
import '../presence/presence_controller.dart';
import 'chat_controller.dart';
import 'chat_search_sheet.dart';
import 'conversation_metadata.dart';
import 'media_message.dart';

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
  bool _uploading = false;
  double _uploadProgress = 0;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;

  @override
  void initState() {
    super.initState();
    _composer.addListener(() => setState(() {}));
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onOpen());
  }

  @override
  void dispose() {
    _composer.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Marking read only when the newest message is actually on screen keeps the
  /// unread badge honest for messages the user has not scrolled to yet.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 40) {
      unawaited(ref.read(chatControllerProvider(widget.conversationId)).markRead());
    }
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

  Future<void> _pickImage() async {
    if (_uploading) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      imageQuality: 92,
    );
    if (picked == null) return;

    await _withUploadProgress(
      (onProgress) => ref.read(chatControllerProvider(widget.conversationId)).sendImage(
            File(picked.path),
            onProgress: onProgress,
          ),
    );
  }

  Future<void> _pickFile() async {
    if (_uploading) return;
    final file = await FilePicker.pickFile();
    if (file == null || file.path == null) return;

    await _withUploadProgress(
      (onProgress) => ref.read(chatControllerProvider(widget.conversationId)).sendFile(
            File(file.path!),
            displayName: file.name,
            contentType: null,
            onProgress: onProgress,
          ),
    );
  }

  Future<void> _withUploadProgress(Future<void> Function(void Function(int, int)?) action) async {
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });
    try {
      await action((sent, total) {
        if (!mounted || total <= 0) return;
        setState(() => _uploadProgress = sent / total);
      });
      await _scrollToBottom();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = 0;
        });
      }
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
    final peer = selfId == null ? null : metadata.value?.otherMember(selfId);
    final peerLabel = peer?.user.displayName;
    final title = cached?.peerName != null
        ? _peerLabelFromCache(cached!)
        : (peerLabel ??
            cached?.name ??
            metadata.value?.displayName(selfId ?? '') ??
            'Chat');
    final isGroup = cached?.type == 'group' || metadata.value?.isGroup == true;

    // Register the peer id so outgoing text can be encrypted for this chat.
    // The local row only caches the peer's name, so the member list is the
    // authoritative source for the id.
    if (!isGroup && selfId != null) {
      final peer = metadata.value?.otherMember(selfId);
      if (peer != null) {
        ref
            .read(e2eeManagerProvider)
            .rememberConversation(
              widget.conversationId,
              selfId: selfId,
              peerId: peer.user.id,
            );
      }
    }

    // For a 1:1 chat the other participant's live presence is the subtitle.
    final presence = !isGroup && peer != null
        ? ref.watch(presenceProvider(peer.user.id))
        : null;
    final presenceLabel = !isGroup ? formatPresence(presence) : null;

    // Sender names make a group thread readable; direct chats already imply it.
    final senderNames = <String, String>{
      if (metadata.value != null)
        for (final member in metadata.value!.members) member.user.id: member.user.displayName,
    };

    ref.listen(messagesProvider(widget.conversationId), (_, _) {
      // Incoming messages while the screen is open are read immediately.
      unawaited(ref.read(chatControllerProvider(widget.conversationId)).markRead());
    });

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: isGroup
                      ? MediaAvatar(
                          objectKey: cached?.avatarUrl,
                          radius: 16,
                          fallback: const Icon(Icons.groups),
                        )
                      : UserAvatarWithStatus(
                          avatarKey: peer?.user.avatarUrl ?? cached?.peerAvatarUrl,
                          name: peer?.user.name ?? cached?.peerName ?? title,
                          status: presence?.resolvedStatus,
                          radius: 16,
                          showStatus: false,
                        ),
                ),
                if (!isGroup && presence != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: StatusBadge(status: presence.resolvedStatus, size: 10),
                  ),
                Flexible(
                  child: Text(title, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (presenceLabel != null)
              Text(
                presenceLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: presence?.isActive == true
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search in chat',
            icon: const Icon(Icons.search),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => ChatSearchSheet(conversationId: widget.conversationId),
            ),
          ),
          if (isGroup)
            IconButton(
              tooltip: 'Group info',
              icon: const Icon(Icons.info_outline),
              onPressed: () => context.push('/conversations/${widget.conversationId}/info'),
            ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          if (_uploading)
            LinearProgressIndicator(value: _uploadProgress == 0 ? null : _uploadProgress),
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
                      showGroupReceipt: isGroup,
                      senderName: message.senderId == selfId ? null : senderNames[message.senderId],
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
                  IconButton(
                    onPressed: _uploading ? null : _pickImage,
                    tooltip: 'Send photo',
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    onPressed: _uploading ? null : _pickFile,
                    tooltip: 'Send file',
                    icon: const Icon(Icons.attach_file),
                  ),
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
                    onPressed: _composer.text.trim().isEmpty || _sending || _uploading
                        ? null
                        : _send,
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

/// "Name (nickname)" from the cached direct-chat peer fields.
String _peerLabelFromCache(LocalConversation conversation) {
  final name = conversation.peerName ?? conversation.name ?? 'Chat';
  final nickname = conversation.peerNickname?.trim();
  if (nickname == null || nickname.isEmpty) return name;
  return '$name ($nickname)';
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.showGroupReceipt,
    required this.senderName,
    required this.onRetry,
    required this.onDiscard,
  });

  final LocalMessage message;
  final bool isMine;
  final bool showGroupReceipt;
  final String? senderName;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  bool get _failed => message.status == 'failed';
  bool get _isImage => message.type == 'image';
  bool get _isFile => message.type == 'file';

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
                    if (senderName != null) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          senderName!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _body(theme, foreground),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isMine && showGroupReceipt && _groupReceiptLabel() != null) ...[
                          Text(
                            _groupReceiptLabel()!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: foreground.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
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

  /// Text, image or file body. Media content stores the object key plus an
  /// optional caption so the same bubble can render both.
  Widget _body(ThemeData theme, Color foreground) {
    if (_isImage) return ImageMessage(content: message.content);
    if (_isFile) return FileMessage(content: message.content);
    return Text(
      message.content,
      style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
    );
  }

  /// "Read by 3" for group messages this user sent, once a receipt arrives.
  String? _groupReceiptLabel() {
    final read = message.readCount;
    final total = message.memberCount;
    if (read == null || total == null || total == 0) return null;
    if (read >= total) return 'Read by all';
    return 'Read by $read';
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
