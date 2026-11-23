import 'package:material_ui/material_ui.dart';

import 'status_colors.dart';

/// A Discord-style presence indicator.
///
/// - `online`: solid green circle
/// - `idle`: amber circle with a crescent notch
/// - `dnd`: red circle with a horizontal dash
/// - `offline` / `invisible`: hollow grey ring
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.status,
    this.size = 12,
    this.borderColor,
  });

  final String? status;
  final double size;

  /// Ring colour drawn around the dot so it reads on any avatar background.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final resolved = (status == null || status == 'invisible') ? 'offline' : status;
    final ring = borderColor ?? Theme.of(context).colorScheme.surface;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: StatusColors.of(resolved),
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: size * 0.16),
      ),
      child: switch (resolved) {
        'idle' => _IdleNotch(color: ring, size: size),
        'dnd' => Center(
            child: Container(
              width: size * 0.5,
              height: size * 0.16,
              decoration: BoxDecoration(
                color: ring,
                borderRadius: BorderRadius.circular(size),
              ),
            ),
          ),
        'offline' => Center(
            child: Container(
              width: size * 0.34,
              height: size * 0.34,
              decoration: BoxDecoration(
                color: ring,
                shape: BoxShape.circle,
              ),
            ),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

/// Cuts the "sleeping" crescent out of the idle dot using a surrounding arc.
class _IdleNotch extends StatelessWidget {
  const _IdleNotch({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Stack(
        children: [
          Positioned(
            top: -size * 0.12,
            left: -size * 0.12,
            child: Container(
              width: size * 0.6,
              height: size * 0.52,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ],
      ),
    );
  }
}
