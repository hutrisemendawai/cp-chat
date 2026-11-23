import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_widgets.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_search_picker.dart';

import 'group_controller.dart';

/// Group details and administration, styled after the Stitch "Group info"
/// screen: divided settings rows, a members section with an emerald Add action,
/// and a destructive leave row at the bottom.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  Conversation? _conversation;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conversation =
          await ref.read(apiClientProvider).conversation(widget.conversationId);
      await ref.read(chatDaoProvider).upsertConversation(
            conversation,
            selfId: ref.read(currentUserProvider)?.id,
          );
      if (mounted) setState(() => _conversation = conversation);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load group info.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rename() async {
    final current = _conversation;
    if (current == null) return;

    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameGroupDialog(initialName: current.name ?? ''),
    );

    if (name == null || name.isEmpty || name == current.name) return;
    await _run(() async {
      final updated =
          await ref.read(groupControllerProvider).rename(current.id, name);
      if (mounted) setState(() => _conversation = updated);
    });
  }

  Future<void> _changeAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 90,
    );
    if (picked == null) return;

    await _run(() async {
      final key = await ref
          .read(mediaServiceProvider)
          .uploadImage(file: File(picked.path));
      await ref.read(groupControllerProvider).setAvatar(widget.conversationId, key);
      await _load();
    });
  }

  Future<void> _addMembers() async {
    final selfId = ref.read(currentUserProvider)?.id;
    if (selfId == null) return;

    final existing = _conversation?.members.map((member) => member.user.id).toSet() ?? {};
    final picked = await showUserSearchSheet(
      context,
      multiSelect: true,
      excludeIds: {...existing, selfId},
    );
    if (picked.isEmpty || !mounted) return;

    await _run(() async {
      final updated = await ref
          .read(groupControllerProvider)
          .addMembers(widget.conversationId, picked.map((user) => user.id).toList());
      if (mounted) setState(() => _conversation = updated);
    });
  }

  Future<void> _removeMember(User member) async {
    await _run(() async {
      await ref
          .read(groupControllerProvider)
          .removeMember(widget.conversationId, member.id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed ${member.name}')),
        );
      }
    });
  }

  Future<void> _leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text('You will stop receiving messages from this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final selfId = ref.read(currentUserProvider)?.id;
    if (selfId == null) return;

    await _run(() async {
      await ref
          .read(groupControllerProvider)
          .removeMember(widget.conversationId, selfId);
      if (mounted) context.go('/conversations');
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'That did not work. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selfId = ref.watch(currentUserProvider)?.id;
    final conversation = _conversation;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group info')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (conversation == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group info')),
        body: EmptyState(
          icon: Icons.group_off_outlined,
          title: 'Group not available',
          message: _error ?? 'This group could not be loaded.',
          action: FilledButton.tonal(
            onPressed: _load,
            child: const Text('Retry'),
          ),
        ),
      );
    }

    final canManage = _canRemove(conversation, selfId);
    final members = conversation.members;

    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.section),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Group avatar + rename settings rows.
          _SettingsRow(
            icon: Icons.image_outlined,
            title: 'Group avatar',
            subtitle: conversation.avatarUrl == null ? 'No avatar set' : 'Tap to change',
            onTap: canManage && !_busy ? _changeAvatar : null,
          ),
          _SettingsRow(
            icon: Icons.edit_outlined,
            title: 'Rename group',
            subtitle: conversation.name ?? 'Unnamed',
            onTap: canManage && !_busy ? _rename : null,
          ),
          Divider(height: 1, color: scheme.outlineVariant),

          // Members.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.lg,
              AppSpacing.pageMargin,
              AppSpacing.sm,
            ),
            child: SectionLabel(
              text: 'Members (${members.length})',
              trailing: TextButton.icon(
                onPressed: _busy ? null : _addMembers,
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Add'),
              ),
            ),
          ),
          for (var index = 0; index < members.length; index++) ...[
            _MemberRow(
              member: members[index],
              isSelf: members[index].user.id == selfId,
              canRemove: canManage && members[index].user.id != selfId && !_busy,
              onTap: () => context.push('/users/${members[index].user.id}'),
              onRemove: () => _removeMember(members[index].user),
            ),
            if (index < members.length - 1)
              Divider(
                height: 1,
                indent: AppSpacing.lg + 48 + AppSpacing.md,
                endIndent: AppSpacing.lg,
                color: scheme.outlineVariant,
              ),
          ],
          Divider(height: 1, color: scheme.outlineVariant),

          // Destructive leave action.
          InkWell(
            onTap: _busy ? null : _leave,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pageMargin,
                vertical: AppSpacing.lg,
              ),
              child: Row(
                children: [
                  Icon(Icons.logout, size: 20, color: scheme.error),
                  const SizedBox(width: AppSpacing.lg),
                  Text(
                    'Leave group',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _canRemove(Conversation conversation, String? selfId) {
    if (selfId == null) return false;
    return conversation.isAdmin(selfId);
  }
}

/// A settings row: leading glyph, title and secondary value line.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageMargin,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group member row: avatar with presence, name and `Role · contact`.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isSelf,
    required this.canRemove,
    required this.onTap,
    required this.onRemove,
  });

  final ConversationMember member;
  final bool isSelf;
  final bool canRemove;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final detail = [
      member.role == 'admin' ? 'Admin' : 'Member',
      if (member.user.phoneOrEmail != null) member.user.phoneOrEmail!,
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageMargin,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            UserAvatarWithStatus(
              avatarKey: member.user.avatarUrl,
              name: member.user.name,
              status: member.user.effectiveStatus,
              radius: 24,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isSelf
                        ? '${member.user.displayName} (you)'
                        : member.user.displayName,
                    maxLines: 2,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (canRemove)
              IconButton(
                onPressed: onRemove,
                tooltip: 'Remove',
                icon: const Icon(Icons.person_remove_outlined, size: 20),
                color: scheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

/// Owns its text controller for the lifetime of the route: disposing it as soon
/// as `showDialog` resolves would run while the dialog is still animating out.
class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename group'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(labelText: 'Group name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
