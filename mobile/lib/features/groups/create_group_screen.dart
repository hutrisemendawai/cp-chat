import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_search_picker.dart';

import 'group_controller.dart';

/// Creates a group: name plus one or more members chosen by name or email. The
/// creator becomes the sole admin, matching the backend contract.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final List<User> _members = [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _addMembers() async {
    final selfId = ref.read(currentUserProvider)?.id;
    final picked = await showUserSearchSheet(
      context,
      multiSelect: true,
      excludeIds: {
        ..._members.map((member) => member.id),
        ?selfId,
      },
    );
    if (picked.isEmpty || !mounted) return;

    setState(() {
      _error = null;
      for (final user in picked) {
        if (!_members.any((member) => member.id == user.id)) {
          _members.add(user);
        }
      }
    });
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the group a name.');
      return;
    }
    if (_members.isEmpty) {
      setState(() => _error = 'Add at least one member.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final conversation = await ref.read(groupControllerProvider).create(
            name: name,
            memberIds: _members.map((member) => member.id).toList(),
          );
      if (!mounted) return;
      // Replace so Back does not return to the now-stale creation form.
      context.pushReplacement('/conversations/${conversation.id}');
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not create the group. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _nameController,
            enabled: !_busy,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: 'Group name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _addMembers,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Add members by name or email'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          if (_members.isNotEmpty) ...[
            Text('Members (${_members.length})', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final member in _members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatarWithStatus(
                  avatarKey: member.avatarUrl,
                  name: member.displayName,
                  status: member.effectiveStatus,
                ),
                title: Text(member.displayName),
                subtitle: member.phoneOrEmail == null ? null : Text(member.phoneOrEmail!),
                trailing: IconButton(
                  onPressed: _busy
                      ? null
                      : () => setState(
                            () => _members.removeWhere((item) => item.id == member.id),
                          ),
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                ),
              ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create group'),
          ),
        ],
      ),
    );
  }
}
