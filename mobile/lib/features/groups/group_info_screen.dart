import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/user_avatar.dart';

import 'group_controller.dart';

/// Group details and administration: rename, membership, leave.
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

    final controller = TextEditingController(text: current.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

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

    final controller = TextEditingController();
    final userId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add member'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'User id',
            helperText: 'Paste the user id to add.',
          ),
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

    if (userId == null || userId.isEmpty) return;
    await _run(() async {
      final updated = await ref
          .read(groupControllerProvider)
          .addMembers(widget.conversationId, [userId]);
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
    final selfId = ref.watch(currentUserProvider)?.id;
    final conversation = _conversation;

    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : conversation == null
              ? Center(child: Text(_error ?? 'Group not available'))
              : ListView(
                  children: [
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.all(16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.photo_outlined),
                      title: const Text('Group avatar'),
                      subtitle: Text(
                        conversation.avatarUrl == null ? 'No avatar set' : 'Tap to change',
                      ),
                      enabled: !_busy,
                      onTap: _canRemove(conversation, selfId) ? _changeAvatar : null,
                    ),
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Rename group'),
                      subtitle: Text(conversation.name ?? 'Unnamed'),
                      enabled: !_busy,
                      onTap: _rename,
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Members (${conversation.members.length})',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _busy ? null : _addMembers,
                            icon: const Icon(Icons.person_add_alt),
                            label: const Text('Add'),
                          ),
                        ],
                      ),
                    ),
                    for (final member in conversation.members)
                      ListTile(
                        leading: UserAvatarWithStatus(
                          avatarKey: member.user.avatarUrl,
                          name: member.user.name,
                          status: member.user.effectiveStatus,
                        ),
                        title: Text(
                          member.user.id == selfId
                              ? '${member.user.displayName} (you)'
                              : member.user.displayName,
                        ),
                        subtitle: Text(member.role == 'admin' ? 'Admin' : 'Member'),
                        trailing: member.user.id == selfId || !_canRemove(conversation, selfId)
                            ? null
                            : IconButton(
                                onPressed: _busy ? null : () => _removeMember(member.user),
                                tooltip: 'Remove',
                                icon: const Icon(Icons.person_remove_outlined),
                              ),
                      ),
                    const Divider(),
                    ListTile(
                      leading: Icon(Icons.logout, color: theme.colorScheme.error),
                      title: Text(
                        'Leave group',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      enabled: !_busy,
                      onTap: _leave,
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
    );
  }

  bool _canRemove(Conversation conversation, String? selfId) {
    if (selfId == null) return false;
    return conversation.isAdmin(selfId);
  }
}
