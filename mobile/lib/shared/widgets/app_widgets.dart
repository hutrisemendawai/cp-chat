import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';

/// Section heading used above grouped lists (`Friends`, `Members (3)`).
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.text,
    this.trailing,
    this.emphasized = false,
  });

  final String text;
  final Widget? trailing;

  /// Emphasised labels use the emerald accent (e.g. the People "Friends" head).
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final label = Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: emphasized ? scheme.primary : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );

    if (trailing == null) return label;

    return Row(
      children: [
        Expanded(child: label),
        trailing!,
      ],
    );
  }
}

/// Empty/error state used across the list screens.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.section,
        vertical: 56,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.xl),
            action!,
          ],
        ],
      ),
    );
  }
}

/// The rounded, muted search field used by People, chat search and pickers.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.onClear,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: Icon(Icons.search, size: 20, color: scheme.outline),
        suffixIcon: controller.text.isEmpty || onClear == null
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
              ),
      ),
    );
  }
}
