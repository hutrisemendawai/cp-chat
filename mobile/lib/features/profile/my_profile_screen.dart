import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/status_colors.dart';
import '../../shared/widgets/user_avatar.dart';

/// View and edit the signed-in user's profile: avatar, name, nickname,
/// Discord-style status, custom status and bio.
class MyProfileScreen extends ConsumerStatefulWidget {
  const MyProfileScreen({super.key});

  @override
  ConsumerState<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends ConsumerState<MyProfileScreen> {
  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _nickname = TextEditingController();
  late final TextEditingController _customStatus = TextEditingController();
  late final TextEditingController _bio = TextEditingController();

  User? _user;
  String _status = 'online';
  String? _avatarKey;
  bool _loading = true;
  bool _saving = false;
  bool _uploadingAvatar = false;
  String? _error;

  static const _statusOptions = <({String value, String label, String description})>[
    (value: 'online', label: 'Online', description: 'Available and receiving notifications.'),
    (value: 'idle', label: 'Idle', description: 'Away for a moment.'),
    (value: 'dnd', label: 'Do Not Disturb', description: 'Push notifications are muted.'),
    (value: 'invisible', label: 'Invisible', description: 'You appear offline to everyone.'),
  ];

  @override
  void initState() {
    super.initState();
    for (final controller in [_nickname, _customStatus, _bio, _name]) {
      controller.addListener(_onFieldChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in [_name, _nickname, _customStatus, _bio]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  Future<void> _load() async {
    try {
      final user = await ref.read(apiClientProvider).me();
      if (!mounted) return;
      setState(() {
        _user = user;
        _name.text = user.name;
        _nickname.text = user.nickname ?? '';
        _customStatus.text = user.customStatus ?? '';
        _bio.text = user.bio ?? '';
        _avatarKey = user.avatarUrl;
        _status = user.status ?? 'online';
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  String get _previewName {
    final name = _name.text.trim().isEmpty ? (_user?.name ?? '') : _name.text.trim();
    final nickname = _nickname.text.trim();
    return nickname.isEmpty ? name : '$name ($nickname)';
  }

  Future<void> _pickAvatar(ImageSource source) async {
    if (_uploadingAvatar) return;
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1024,
      imageQuality: 88,
    );
    if (picked == null) return;

    setState(() => _uploadingAvatar = true);
    try {
      final key = await ref.read(mediaServiceProvider).uploadImage(
            file: File(picked.path),
          );
      if (!mounted) return;
      setState(() => _avatarKey = key);
      await _save(avatarKey: key);
    } catch (error) {
      _showError('Could not upload photo: $error');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _removeAvatar() async {
    setState(() => _avatarKey = null);
    await _save(clearAvatar: true);
  }

  Future<void> _save({
    String? avatarKey,
    bool clearAvatar = false,
    bool showConfirmation = false,
  }) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final updated = await ref.read(apiClientProvider).updateProfile(
            name: _name.text.trim().isEmpty ? null : _name.text.trim(),
            nickname: _nickname.text.trim(),
            avatarUrl: avatarKey,
            clearAvatar: clearAvatar,
            status: _status,
            customStatus: _customStatus.text.trim(),
            clearCustomStatus: _customStatus.text.trim().isEmpty,
            bio: _bio.text.trim(),
            clearBio: _bio.text.trim().isEmpty,
          );

      // Reflect the change immediately so headers and the chat list update.
      ref.read(authControllerProvider.notifier).applyUser(updated);
      // Presence broadcasts only reach peers; push the new state on our own
      // socket too so a second device stays consistent.
      ref.read(chatSocketProvider).setPresence(
            status: updated.status ?? _status,
            customStatus: updated.customStatus,
          );

      if (!mounted) return;
      setState(() => _user = updated);
      if (showConfirmation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated')),
        );
      }
    } catch (error) {
      _showError('Could not save profile: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _signOut() async {
    await ref.read(authControllerProvider.notifier).logout();
    if (mounted) context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Profile')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _save(showConfirmation: true),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
          ],
          Center(
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    UserAvatarWithStatus(
                      avatarKey: _avatarKey,
                      name: _previewName,
                      status: _status == 'invisible' ? 'offline' : _status,
                      radius: 44,
                    ),
                    if (_uploadingAvatar)
                      const Positioned.fill(
                        child: CircleAvatar(
                          backgroundColor: Colors.black45,
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(_previewName, style: theme.textTheme.titleLarge),
                if (_user?.phoneOrEmail != null)
                  Text(
                    _user!.phoneOrEmail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _uploadingAvatar
                          ? null
                          : () => _pickAvatar(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Gallery'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _uploadingAvatar
                          ? null
                          : () => _pickAvatar(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Camera'),
                    ),
                    if (_avatarKey != null)
                      TextButton(
                        onPressed: _uploadingAvatar ? null : _removeAvatar,
                        child: const Text('Remove'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            maxLength: 100,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nickname,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Nickname',
              helperText: 'Shown as "Name (nickname)"',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Status', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._statusOptions.map(
            (option) => RadioListTile<String>(
              value: option.value,
              // ignore: deprecated_member_use
              groupValue: _status,
              dense: true,
              contentPadding: EdgeInsets.zero,
              // ignore: deprecated_member_use
              onChanged: (value) {
                if (value == null) return;
                setState(() => _status = value);
                _save();
              },
              secondary: StatusBadge(status: option.value, size: 14),
              title: Text(option.label),
              subtitle: Text(
                option.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _customStatus,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: 'Custom status',
              hintText: 'What are you up to?',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _customStatus.clear();
                  setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            maxLength: 2000,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Bio',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : () => _save(showConfirmation: true),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save changes'),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: StatusColors.dnd,
            ),
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
