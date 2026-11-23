import 'package:material_ui/material_ui.dart';

/// Discord's presence palette, shared by the badge and the status selector.
class StatusColors {
  const StatusColors._();

  static const Color online = Color(0xFF23A55A);
  static const Color idle = Color(0xFFF0B232);
  static const Color dnd = Color(0xFFF23F43);
  static const Color offline = Color(0xFF80848E);

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
