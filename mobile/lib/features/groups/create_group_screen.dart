import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

import 'group_controller.dart';

/// Creates a group: name plus one or more member ids. The creator becomes the
/// sole admin, matching the backend contract.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _memberController = TextEditingController();
  final List<User> _members = [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _memberController.dispose();
    super.dispose();
  }

  Future<void> _addMember() async {
    final query = _memberController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final user = await ref.read(apiClientProvider).user(query);
      final selfId = ref.read(currentUserProvider)?.id;
      if (user.id == selfId) {
        setState(() => _error = 'You are already in the group.');
      } else if (_members.any((member) => member.id == user.id)) {
        setState(() => _error = '${user.name} is already added.');
      } else {
        setState(() {
          _members.add(user);
          _memberController.clear();
        });
      }
    } on ApiException catch (error) {
      setState(() => _error = error.code == 'not_found'
          ? 'No user with that id.'
          : error.message);
    } catch (_) {
      setState(() => _error = 'Lookup failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _memberController,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addMember(),
                  decoration: const InputDecoration(
                    labelText: 'Add member by user id',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _busy ? null : _addMember,
                tooltip: 'Add member',
                icon: const Icon(Icons.person_add_alt),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          if (_members.isNotEmpty) ...[
            Text('Members', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final member in _members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text(member.name.characters.first.toUpperCase()),
                ),
                title: Text(member.name),
                subtitle: Text(member.id),
                trailing: IconButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _members.removeWhere((item) => item.id == member.id)),
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
