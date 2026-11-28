import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/crypto/e2ee_service.dart' show isEncryptedContent, undecryptableContent;
import '../../core/database/app_database.dart';
import '../../core/models/call_models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/connection_banner.dart';
import '../../shared/widgets/user_avatar.dart';
import '../calls/call_controller.dart';
import '../calls/widgets/active_call_banner.dart';
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

class _ChatScreenState extends ConsumerState<ChatScreen> with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _composerFocusNode = FocusNode();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;

  /// The feed is reversed, so offset 0 is the newest message right above the
  /// composer. This tracks whether the user is still reading the live edge.
  bool _isNearBottom = true;
  double _viewInsetBottom = 0;

  /// Captured in initState so the provider can be updated from dispose without
  /// touching `ref`, which is unsafe once the widget is unmounted.
  late final ActiveConversationNotifier _activeConversation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeConversation = ref.read(activeConversationIdProvider.notifier);
    _composer.addListener(() => setState(() {}));
    _composerFocusNode.addListener(_onComposerFocus);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeConversation.open(widget.conversationId);
      _onOpen();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activeConversation.close(widget.conversationId);
    _composer.dispose();
    _composerFocusNode.removeListener(_onComposerFocus);
    _composerFocusNode.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Marking read only when the newest message is actually on screen keeps the
  /// unread badge honest for messages the user has not scrolled to yet.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _isNearBottom = _scrollController.position.pixels <= 80;
    if (_isNearBottom) {
      unawaited(ref.read(chatControllerProvider(widget.conversationId)).markRead());
    }
  }

  /// The soft keyboard shrinks the viewport from the bottom. When the user is at
  /// the live edge, re-pin to offset 0 so the newest message stays visible above
  /// the composer instead of being covered.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = View.of(context).viewInsets.bottom;
    final opening = inset > _viewInsetBottom;
    _viewInsetBottom = inset;
    if (opening && _isNearBottom) {
      unawaited(_scrollToBottom());
    }
  }

  void _onComposerFocus() {
    if (_composerFocusNode.hasFocus && _isNearBottom) {
      unawaited(_scrollToBottom());
    }
  }

  Future<void> _onOpen() async {
    // Opening the chat clears any banner already raised for it.
    unawaited(
      ref.read(localNotificationServiceProvider).cancelForConversation(
            widget.conversationId,
            accountId: ref.read(accountScopeProvider)?.accountId,
          ),
    );
    final controller = ref.read(chatControllerProvider(widget.conversationId));
    // Hydrate any live group call banner for this chat.
    unawaited(
      ref
          .read(callControllerProvider.notifier)
          .refreshConversationActiveCall(widget.conversationId),
    );
    // Catch up on anything missed, then mark the newest message read.
    await ref.read(chatSocketProvider).syncAll(selfId: ref.read(currentUserProvider)?.id);
    await controller.markRead();
    await _scrollToBottom();
  }

  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'This removes all messages in this chat from this device and prevents '
          'cleared history from re-syncing. Your encryption keys stay intact so '
          'future messages continue to work.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear chat'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final scope = ref.read(accountScopeProvider);
    if (scope == null) return;
    await ref.read(accountWiperProvider).clearConversation(
          accountId: scope.accountId,
          conversationId: widget.conversationId,
          dao: ref.read(chatDaoProvider),
          api: ref.read(apiClientProvider),
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat history cleared')),
      );
    }
  }

  Future<void> _confirmResetEncryption() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset encryption on this device?'),
        content: const Text(
          'Your account published different encryption keys on another device. '
          'Resetting generates fresh keys for this device so you can send '
          'messages again. Local readable history stays on this device; '
          'earlier encrypted history on the server is not restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset encryption'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(e2eeManagerProvider).resetEncryption();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Encryption keys reset on this device')),
      );
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _composer.clear();
    try {
      await ref.read(chatControllerProvider(widget.conversationId)).sendText(text);
      await _scrollToBottom();
    } on E2eeSendException catch (error) {
      // Nothing left the device, so give the text back to the user instead of
      // losing it.
      if (mounted) {
        _composer.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
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
    // A reversed feed anchors the newest message at offset 0.
    _scrollController.jumpTo(0);
    _isNearBottom = true;
  }

  Future<void> _startCall({
    required CallMediaType mediaType,
    required bool isGroup,
    required String title,
    String? peerAvatarUrl,
    bool allowAudioFallback = false,
  }) async {
    final feedback = await ref.read(callControllerProvider.notifier).startCall(
          conversationId: widget.conversationId,
          mediaType: mediaType,
          isGroup: isGroup,
          title: title,
          peerAvatarUrl: peerAvatarUrl,
          allowAudioFallback: allowAudioFallback,
        );
    if (!mounted) return;
    await _handleCallFeedback(
      feedback,
      onAudioFallback: () => _startCall(
        mediaType: CallMediaType.voice,
        isGroup: isGroup,
        title: title,
        peerAvatarUrl: peerAvatarUrl,
        allowAudioFallback: true,
      ),
    );
  }

  Future<void> _joinGroupCall(
    ActiveCallSummary summary, {
    required String title,
  }) async {
    final feedback = await ref.read(callControllerProvider.notifier).joinGroupCall(
          summary,
          title: title,
          enableVideo: summary.isVideo,
        );
    if (!mounted) return;
    await _handleCallFeedback(feedback);
  }

  Future<void> _handleCallFeedback(
    CallStartFeedback feedback, {
    Future<void> Function()? onAudioFallback,
  }) async {
    switch (feedback) {
      case CallStartFeedback.started:
        return;
      case CallStartFeedback.permissionPermanentlyDenied:
        final perms = ref.read(callPermissionServiceProvider);
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Call permissions required'),
            content: const Text(
              'CP Chat needs microphone (and camera for video) permission to place calls. '
              'Please enable it in Android app settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(perms.openSettings());
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
      case CallStartFeedback.cameraDeniedAudioFallback:
        if (onAudioFallback == null) return;
        final fallback = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Camera permission denied'),
            content: const Text(
              'Camera access was denied. Would you like to start this call with audio only?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Join with audio only'),
              ),
            ],
          ),
        );
        if (fallback == true && mounted) {
          await onAudioFallback();
        }
      case CallStartFeedback.permissionDenied:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required for calls.'),
          ),
        );
      case CallStartFeedback.busy:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Already in another call.')),
        );
      case CallStartFeedback.unavailable:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Calling service is currently unavailable.')),
        );
      case CallStartFeedback.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start call.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selfId = ref.watch(currentUserProvider)?.id;
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final conversation = ref.watch(conversationLocalProvider(widget.conversationId));
    final metadata = ref.watch(conversationMetadataProvider(widget.conversationId));

    final cached = conversation.value;
    // Group state must be known before the peer is resolved: a group has no
    // "other member", so the header shows the group name instead of a member.
    final isGroup = cached?.type == 'group' || metadata.value?.isGroup == true;
    final peer = isGroup || selfId == null ? null : metadata.value?.otherMember(selfId);
    final title = isGroup
        ? (metadata.value?.name?.trim().isNotEmpty == true
            ? metadata.value!.name!
            : (cached?.name?.trim().isNotEmpty == true ? cached!.name! : 'Group'))
        : (peer?.user.displayName ??
            (cached?.peerName != null ? _peerLabelFromCache(cached!) : null) ??
            cached?.name ??
            'Chat');

    // The direct peer's id: the authoritative member list wins, but a chat that
    // was opened from a fresh inbound message may only have the cached row
    // before `conversationMetadataProvider` resolves (or while offline).
    final peerUserId = !isGroup ? (peer?.user.id ?? cached?.peerId) : null;

    // Register the peer id so outgoing text can be encrypted for this chat even
    // before the member list loads — never fall back to plaintext.
    if (!isGroup && selfId != null && peerUserId != null) {
      ref
          .read(e2eeManagerProvider)
          .rememberConversation(
            widget.conversationId,
            selfId: selfId,
            peerId: peerUserId,
          );
    }

    // For a 1:1 chat the other participant's live presence is the subtitle.
    final presence = !isGroup && peerUserId != null
        ? ref.watch(presenceProvider(peerUserId))
        : null;
    final presenceLabel = !isGroup ? formatPresence(presence) : null;

    // A group header summarises the roster once the member list is loaded.
    final groupSubtitle = isGroup && metadata.value != null
        ? '${metadata.value!.members.length} members'
        : null;

    final callState = ref.watch(callControllerProvider);
    final activeGroupCall = isGroup
        ? ref.watch(activeGroupCallsProvider)[widget.conversationId]
        : null;
    final inCallForThisChat =
        callState.isLiveSession && callState.currentConversationId == widget.conversationId;
    final peerAvatar = peer?.user.avatarUrl ?? cached?.peerAvatarUrl;

    // Tapping the header opens a group's info, or a direct chat's peer profile.

    // Sender names make a group thread readable; direct chats already imply it.
    final senderNames = <String, String>{
      if (metadata.value != null)
        for (final member in metadata.value!.members) member.user.id: member.user.displayName,
    };

    ref.listen(messagesProvider(widget.conversationId), (previous, next) {
      unawaited(ref.read(chatControllerProvider(widget.conversationId)).markRead());
      final items = next.value;
      if (items == null || items.isEmpty) return;
      final previousItems = previous?.value;
      final grew = previousItems == null || items.length > previousItems.length;
      if (!grew) return;
      // Follow the live edge when the user sent the message or is already at the
      // bottom; never yank someone who scrolled up to read history.
      if (items.last.senderId == selfId || _isNearBottom) {
        unawaited(_scrollToBottom());
      }
    });

    return Scaffold(
      // The message feed sits on the design system's chat wallpaper.
      backgroundColor: context.chatTheme.wallpaper,
      appBar: AppBar(
        titleSpacing: AppSpacing.xs,
        title: InkWell(
          onTap: isGroup
              ? () => context.push('/conversations/${widget.conversationId}/info')
              : (peerUserId == null ? null : () => context.push('/users/$peerUserId')),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                isGroup
                    ? MediaAvatar(
                        objectKey: cached?.avatarUrl,
                        radius: 18,
                        fallback: const Icon(Icons.group, size: 18),
                      )
                    : UserAvatarWithStatus(
                        avatarKey: peer?.user.avatarUrl ?? cached?.peerAvatarUrl,
                        name: peer?.user.name ?? cached?.peerName ?? title,
                        status: presence?.resolvedStatus,
                        radius: 18,
                      ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (presenceLabel != null)
                        Text(
                          presenceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: presence?.isActive == true
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      else if (groupSubtitle != null)
                        Text(
                          groupSubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (inCallForThisChat)
            IconButton(
              tooltip: 'Return to call',
              icon: const Icon(Icons.call, color: AppColors.whatsappEmerald),
              onPressed: () {
                ref.read(callControllerProvider.notifier).setMinimized(false);
              },
            )
          else ...[
            IconButton(
              tooltip: 'Voice call',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => unawaited(
                _startCall(
                  mediaType: CallMediaType.voice,
                  isGroup: isGroup,
                  title: title,
                  peerAvatarUrl: peerAvatar,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => unawaited(
                _startCall(
                  mediaType: CallMediaType.video,
                  isGroup: isGroup,
                  title: title,
                  peerAvatarUrl: peerAvatar,
                ),
              ),
            ),
          ],
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
          PopupMenuButton<String>(
            tooltip: 'Chat options',
            onSelected: (value) {
              if (value == 'clear') {
                unawaited(_confirmClearChat());
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('Clear chat'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          if (isGroup && activeGroupCall != null && !inCallForThisChat)
            GroupActiveCallBanner(
              summary: activeGroupCall,
              onJoin: () => unawaited(
                _joinGroupCall(activeGroupCall, title: title),
              ),
            ),
          if (!isGroup)
            ValueListenableBuilder<bool>(
              valueListenable: ref.watch(e2eeManagerProvider).keyMismatch,
              builder: (context, mismatch, _) {
                if (!mismatch) return const SizedBox.shrink();
                return _KeyMismatchBanner(onReset: _confirmResetEncryption);
              },
            ),
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
                      'No messages yet',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final displayItems = _collapseUndecryptableRuns(items);
                return ListView.builder(
                  controller: _scrollController,
                  // Reversed so offset 0 is the newest message pinned right above
                  // the composer; the keyboard then pushes the thread up instead
                  // of covering it.
                  reverse: true,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.pageMargin,
                    vertical: AppSpacing.lg,
                  ),
                  itemCount: displayItems.length + (_hasMoreHistory ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_hasMoreHistory && index == displayItems.length) {
                      return Center(
                        child: TextButton(
                          onPressed: _loadingOlder ? null : _loadOlder,
                          child: Text(_loadingOlder ? 'Loading…' : 'Load earlier messages'),
                        ),
                      );
                    }
                    final entry = displayItems[displayItems.length - 1 - index];
                    if (entry.systemText != null) {
                      return _SystemNoticeRow(text: entry.systemText!);
                    }
                    final message = entry.message!;
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
          ValueListenableBuilder<bool>(
            valueListenable: ref.watch(e2eeManagerProvider).keyMismatch,
            builder: (context, mismatch, _) {
              final sendBlocked = !isGroup && mismatch;
              return _Composer(
                controller: _composer,
                focusNode: _composerFocusNode,
                uploading: _uploading,
                canSend: !sendBlocked &&
                    _composer.text.trim().isNotEmpty &&
                    !_sending &&
                    !_uploading,
                onPickImage: _pickImage,
                onPickFile: _pickFile,
                onSend: _send,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Sticky composer from the design system: a rounded `surface-container-high`
/// capsule with attach actions and an emerald circular send button.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.uploading,
    required this.canSend,
    required this.onPickImage,
    required this.onPickFile,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool uploading;
  final bool canSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.sm,
          AppSpacing.pageMargin,
          AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: uploading ? null : onPickImage,
                      tooltip: 'Send photo',
                      icon: const Icon(Icons.image_outlined),
                      color: scheme.onSurfaceVariant,
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 5,
                        enabled: !uploading,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.newline,
                        style: theme.textTheme.bodyLarge,
                        decoration: InputDecoration(
                          hintText: 'Message',
                          filled: false,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: uploading ? null : onPickFile,
                      tooltip: 'Send file',
                      icon: const Icon(Icons.attach_file),
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 44,
              height: 44,
              child: Material(
                color: AppColors.whatsappEmerald,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: canSend ? onSend : null,
                  child: Icon(
                    Icons.send,
                    size: 20,
                    color: canSend
                        ? scheme.onPrimaryContainer
                        : scheme.onPrimaryContainer.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live local row for the header, so the peer name appears without a round trip.
final conversationLocalProvider =
    StreamProvider.family<LocalConversation?, String>((ref, conversationId) {
  ref.watch(accountScopeProvider);
  return ref.watch(chatDaoProvider).watchConversation(conversationId);
});

/// Either a regular message bubble or a collapsed system notice row.
class _FeedItem {
  const _FeedItem.message(this.message) : systemText = null;
  const _FeedItem.system(this.systemText) : message = null;

  final LocalMessage? message;
  final String? systemText;
}

/// Collapses consecutive undecryptable messages into a single neutral system
/// notice ("Secure session reset – ask them to resend") instead of flooding the
/// timeline with N stub bubbles (§2.7).
List<_FeedItem> _collapseUndecryptableRuns(List<LocalMessage> items) {
  final out = <_FeedItem>[];
  var inUndecryptableRun = false;
  for (final msg in items) {
    if (msg.type == 'system') {
      inUndecryptableRun = false;
      out.add(_FeedItem.system(msg.content));
      continue;
    }
    final unreadable = msg.type == 'text' &&
        (msg.content == undecryptableContent || isEncryptedContent(msg.content));
    if (unreadable) {
      if (!inUndecryptableRun) {
        inUndecryptableRun = true;
        out.add(const _FeedItem.system('Secure session reset – ask them to resend'));
      }
      continue;
    }
    inUndecryptableRun = false;
    out.add(_FeedItem.message(msg));
  }
  return out;
}

class _SystemNoticeRow extends StatelessWidget {
  const _SystemNoticeRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_reset, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyMismatchBanner extends StatelessWidget {
  const _KeyMismatchBanner({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageMargin,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.vpn_key_off_outlined, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Encryption keys changed on another device. Sending is paused.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: onReset,
              child: const Text('Reset encryption'),
            ),
          ],
        ),
      ),
    );
  }
}

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
    final chat = context.chatTheme;

    // Design system bubble tokens: outgoing uses `chat-bubble-out`, incoming
    // `chat-bubble-in`; a failed send falls back to the error container.
    final background = _failed
        ? scheme.errorContainer
        : (isMine ? chat.bubbleOut : chat.bubbleIn);
    final foreground = _failed
        ? scheme.onErrorContainer
        : (isMine ? chat.onBubbleOut : chat.onBubbleIn);
    final metaColor = scheme.onSurfaceVariant;

    // 16px radius with a tighter 4px corner on the sender's side.
    const bubbleRadius = Radius.circular(AppRadius.lg);
    const tailRadius = Radius.circular(AppRadius.sm);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: Material(
            color: background,
            borderRadius: BorderRadius.only(
              topLeft: isMine ? bubbleRadius : tailRadius,
              topRight: isMine ? tailRadius : bubbleRadius,
              bottomLeft: bubbleRadius,
              bottomRight: bubbleRadius,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onLongPress: isMine ? () => _showActions(context) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
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
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _body(theme, foreground),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isMine && showGroupReceipt && _groupReceiptLabel() != null) ...[
                          Text(
                            _groupReceiptLabel()!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: metaColor,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        Text(
                          _time(message.createdAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: metaColor,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: AppSpacing.xs),
                          _StatusIcon(status: message.status),
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
    // A raw envelope must never be rendered as text, e.g. an own message synced
    // back before the plaintext row existed.
    final encrypted = isEncryptedContent(message.content);
    return Text(
      encrypted ? undecryptableContent : message.content,
      style: encrypted
          // Encrypted envelopes are rendered in the mono face, per the design
          // system's `mono-sm` role.
          ? theme.textTheme.labelSmall?.copyWith(
              fontFamily: AppTypography.mono,
              color: foreground,
              height: 16 / 12,
            )
          : theme.textTheme.bodyMedium?.copyWith(color: foreground, height: 20 / 14),
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
  const _StatusIcon({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, tooltip) = switch (status) {
      'pending' => (Icons.schedule, 'Sending'),
      'sent' => (Icons.check, 'Sent'),
      'delivered' => (Icons.done_all, 'Delivered'),
      'read' => (Icons.done_all, 'Read'),
      'failed' => (Icons.error_outline, 'Failed to send'),
      _ => (Icons.schedule, 'Sending'),
    };

    // The design system uses `read-receipt` (#53BDEB) for read ticks; earlier
    // states stay muted so the difference is unmistakable.
    final color = switch (status) {
      'read' => AppColors.readReceipt,
      'failed' => scheme.error,
      _ => scheme.onSurfaceVariant,
    };

    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: 14, color: color),
    );
  }
}
