import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/status_colors.dart';
import '../../shared/widgets/user_avatar.dart';

/// View and edit the signed-in user's profile, styled after the Stitch
/// "My Profile" screen: a large status-rimmed avatar, outlined gallery/camera
/// pills, labelled text fields with counters, and a grouped status radio list.
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
  bool _signingOut = false;
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
    if (_signingOut) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _signingOut = true);
    try {
      await ref.read(authControllerProvider.notifier).logout();
    } finally {
      if (mounted) context.go('/auth');
    }
  }

  /// AppBar sign-out, available even while the profile is still loading or has
  /// failed, so the user is never stuck without a way off the screen.
  Widget _signOutAction() {
    if (_signingOut) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: 'Sign out',
      icon: const Icon(Icons.logout),
      onPressed: _signOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('My Profile'),
          actions: [_signOutAction()],
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: TextButton(
              onPressed: _saving ? null : () => _save(showConfirmation: true),
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
          _signOutAction(),
        ],
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.xl,
          AppSpacing.pageMargin,
          AppSpacing.section + 32,
        ),
        children: [
          if (_error != null) ...[
            _ErrorBanner(message: _error!),
            const SizedBox(height: AppSpacing.lg),
          ],
          _identityHeader(theme),
          const SizedBox(height: AppSpacing.xl),
          _labelledField(
            label: 'Name',
            controller: _name,
            maxLength: 100,
            hint: 'Enter your name',
            capitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppSpacing.lg),
          _labelledField(
            label: 'Nickname',
            controller: _nickname,
            maxLength: 60,
            hint: 'Enter a nickname',
            hintBelow: 'Shown as "Name (nickname)"',
          ),
          const SizedBox(height: AppSpacing.xl),
          _statusSection(theme),
          const SizedBox(height: AppSpacing.xl),
          _customStatusField(theme),
          const SizedBox(height: AppSpacing.lg),
          _labelledField(
            label: 'Bio',
            controller: _bio,
            maxLength: 2000,
            hint: 'Tell people a little about yourself',
            capitalization: TextCapitalization.sentences,
            minLines: 3,
            maxLines: 6,
          ),
          const SizedBox(height: AppSpacing.xl),
          SafeArea(
            top: false,
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: StatusColors.dnd,
                  side: BorderSide(color: theme.colorScheme.errorContainer),
                ),
                onPressed: _signingOut ? null : _signOut,
                icon: _signingOut
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout, size: 18),
                label: Text(_signingOut ? 'Signing out…' : 'Sign out'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Large avatar with a presence rim, display name, contact line and the two
  /// outlined media pills from the design system.
  Widget _identityHeader(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            UserAvatarWithStatus(
              avatarKey: _avatarKey,
              name: _previewName,
              status: _status,
              radius: 40,
            ),
            if (_uploadingAvatar)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          _previewName,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineLarge,
        ),
        if (_user?.phoneOrEmail != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _user!.phoneOrEmail!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          alignment: WrapAlignment.center,
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
    );
  }

  /// Grouped radio list, matching the design system's status selector.
  Widget _statusSection(ThemeData theme) {
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Status', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < _statusOptions.length; index++) ...[
                if (index > 0)
                  Divider(height: 1, color: scheme.outlineVariant),
                _StatusOptionTile(
                  option: _statusOptions[index],
                  selected: _status == _statusOptions[index].value,
                  onTap: _saving
                      ? null
                      : () {
                          setState(() => _status = _statusOptions[index].value);
                          _save();
                        },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _customStatusField(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Custom status',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: _customStatus,
          maxLength: 120,
          decoration: InputDecoration(
            hintText: 'Set a custom status',
            filled: false,
            counterText: '${_customStatus.text.characters.length}/120',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            suffixIcon: _customStatus.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _customStatus.clear();
                      setState(() {});
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// A labelled input with a triangular counter, per the design system's
  /// `input-field-text` component.
  Widget _labelledField({
    required String label,
    required TextEditingController controller,
    required int maxLength,
    required String hint,
    TextCapitalization capitalization = TextCapitalization.none,
    String? hintBelow,
    int minLines = 1,
    int maxLines = 1,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: controller,
          maxLength: maxLength,
          minLines: minLines,
          maxLines: maxLines,
          textCapitalization: capitalization,
          decoration: InputDecoration(
            hintText: hint,
            filled: false,
            counterText: '${controller.text.characters.length}/$maxLength',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              borderSide: const BorderSide(
                color: Color(0xFF00A884),
                width: 1.5,
              ),
            ),
          ),
        ),
        if (hintBelow != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              hintBelow,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// One row of the grouped status selector: label, description and presence dot.
class _StatusOptionTile extends StatelessWidget {
  const _StatusOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ({String value, String label, String description}) option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(option.label, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: StatusColors.of(option.value),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline error banner using the design system's error container tones.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
