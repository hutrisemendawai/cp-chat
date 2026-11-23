import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_colors.dart';

/// Presence palette from the Stitch design system (`status-*` tokens).
class StatusColors {
  const StatusColors._();

  static const Color online = AppColors.statusOnline;
  static const Color idle = AppColors.statusIdle;
  static const Color dnd = AppColors.statusDnd;
  static const Color offline = AppColors.statusOffline;

  /// Colour for a status string, treating `invisible` as offline.
  static Color of(String? status) {
    switch (status) {
      case 'online':
        return online;
      case 'idle':
        return idle;
      case 'dnd':
        return dnd;
      default:
        return offline;
    }
  }
}
