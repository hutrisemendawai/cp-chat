import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import 'user_avatar.dart';

/// Opens the Name/Email search picker in a bottom sheet.
///
/// Returns the selected users (empty when dismissed). Single-select sheets pick
/// immediately on tap; multi-select sheets show a confirm button.
Future<List<User>> showUserSearchSheet(
  BuildContext context, {
  bool multiSelect = false,
  Set<String> excludeIds = const <String>{},
}) async {
  final picked = await showModalBottomSheet<List<User>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final height = MediaQuery.sizeOf(sheetContext).height * 0.85;
      return SizedBox(
        height: height,
        child: _UserSearchSheet(
          multiSelect: multiSelect,
          excludeIds: excludeIds,
        ),
      );
    },
  );
  return picked ?? const [];
}

class _UserSearchSheet extends ConsumerStatefulWidget {
  const _UserSearchSheet({required this.multiSelect, required this.excludeIds});

  final bool multiSelect;
  final Set<String> excludeIds;

  @override
  ConsumerState<_UserSearchSheet> createState() => _UserSearchSheetState();
}

class _UserSearchSheetState extends ConsumerState<_UserSearchSheet> {
  final Map<String, User> _selected = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.multiSelect ? 'Add people' : 'New chat',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: UserSearchPicker(
            multiSelect: widget.multiSelect,
            excludeIds: widget.excludeIds,
            autofocus: true,
            onPick: widget.multiSelect
                ? null
                : (user) => Navigator.of(context).pop([user]),
            onSelectionChanged: (users) => setState(() {
              _selected
                ..clear()
                ..addEntries(users.map((user) => MapEntry(user.id, user)));
            }),
          ),
        ),
        if (widget.multiSelect)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selected.values.toList()),
                  child: Text(
                    _selected.isEmpty ? 'Select people' : 'Add ${_selected.length}',
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Debounced live search by **name or email** with the caller's friends shown as
/// quick-select chips while the query is empty. Users are picked by identity,
/// never by pasting a UUID.
class UserSearchPicker extends ConsumerStatefulWidget {
  const UserSearchPicker({
    super.key,
    this.multiSelect = false,
    this.excludeIds = const <String>{},
    this.onPick,
    this.onSelectionChanged,
    this.autofocus = false,
  });

  /// When true, tapping toggles membership and [onSelectionChanged] fires.
  final bool multiSelect;

  /// Users to hide from results (the caller, existing members).
  final Set<String> excludeIds;

  /// Called in single-select mode when a user is tapped.
  final ValueChanged<User>? onPick;

  /// Called in multi-select mode whenever the selection changes.
  final ValueChanged<List<User>>? onSelectionChanged;

  final bool autofocus;

  @override
  ConsumerState<UserSearchPicker> createState() => _UserSearchPickerState();
}

class _UserSearchPickerState extends ConsumerState<UserSearchPicker> {
  static const _debounceDuration = Duration(milliseconds: 300);

  final _controller = TextEditingController();
  final Map<String, User> _selected = {};

  Timer? _debounce;
  List<User> _friends = const [];
  List<User> _results = const [];
  bool _loading = false;
  bool _friendsLoading = true;
  String? _error;
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFriends());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Set<String> get _hiddenIds => {
        ...widget.excludeIds,
        ?ref.read(currentUserProvider)?.id,
      };

  Future<void> _loadFriends() async {
    try {
      final friends = await ref.read(apiClientProvider).friends();
      if (!mounted) return;
      setState(() {
        _friends = friends.where((user) => !_hiddenIds.contains(user.id)).toList();
        _friendsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _friendsLoading = false);
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(_debounceDuration, () => unawaited(_search(query)));
  }

  Future<void> _search(String query) async {
    final token = ++_requestToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await ref.read(apiClientProvider).searchUsers(query);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _results = users.where((user) => !_hiddenIds.contains(user.id)).toList();
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Check your connection.';
      });
    }
  }

  void _activate(User user) {
    if (widget.multiSelect) {
      setState(() {
        if (_selected.containsKey(user.id)) {
          _selected.remove(user.id);
        } else {
          _selected[user.id] = user;
        }
      });
      widget.onSelectionChanged?.call(_selected.values.toList());
    } else {
      widget.onPick?.call(user);
    }
  }

  bool _isSelected(User user) => _selected.containsKey(user.id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _controller.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: TextField(
            controller: _controller,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            decoration: InputDecoration(
              hintText: 'Search by name or email',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                        setState(() {});
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        Expanded(
          child: query.isEmpty ? _buildFriends(theme) : _buildResults(theme),
        ),
      ],
    );
  }

  Widget _buildFriends(ThemeData theme) {
    if (_friendsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_friends.isEmpty) {
      return const _Hint(
        icon: Icons.group_outlined,
        message: 'No friends yet. Search by name or email to find someone.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Text('Friends', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final friend in _friends)
              FilterChip(
                label: Text(friend.displayName),
                selected: _isSelected(friend),
                onSelected: (_) => _activate(friend),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ..._friends.map(
          (friend) => _UserTile(
            user: friend,
            selected: _isSelected(friend),
            multiSelect: widget.multiSelect,
            onTap: () => _activate(friend),
          ),
        ),
      ],
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const _Hint(
        icon: Icons.person_search_outlined,
        message: 'No one matches that name or email.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        for (final user in _results)
          _UserTile(
            user: user,
            selected: _isSelected(user),
            multiSelect: widget.multiSelect,
            onTap: () => _activate(user),
          ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.selected,
    required this.multiSelect,
    required this.onTap,
  });

  final User user;
  final bool selected;
  final bool multiSelect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = user.phoneOrEmail ?? (user.isFriend ? 'Friend' : '');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: selected,
      onTap: onTap,
      leading: GestureDetector(
        onTap: () => _showUserProfile(context, user),
        child: UserAvatarWithStatus(
          avatarKey: user.avatarUrl,
          name: user.displayName,
          status: user.effectiveStatus,
        ),
      ),
      title: Text(user.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: multiSelect
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : IconButton(
              tooltip: 'View profile',
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showUserProfile(context, user),
            ),
    );
  }
}

/// Lightweight profile card for a search result. The full People profile screen
/// is a later phase; this keeps the identity visible without a UUID.
Future<void> _showUserProfile(BuildContext context, User user) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) {
      final status = user.effectiveStatus ?? 'offline';
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatarWithStatus(
              avatarKey: user.avatarUrl,
              name: user.displayName,
              status: user.effectiveStatus,
              radius: 36,
            ),
            const SizedBox(height: 16),
            Text(user.displayName, style: theme.textTheme.titleLarge),
            if (user.phoneOrEmail != null) ...[
              const SizedBox(height: 4),
              Text(user.phoneOrEmail!, style: theme.textTheme.bodyMedium),
            ],
            if (user.customStatus != null && user.customStatus!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(user.customStatus!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: status == 'offline'
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(status, style: theme.textTheme.labelMedium),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
