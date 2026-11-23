import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import '../network/ws_client.dart';
import '../providers.dart';

/// A slim, non-blocking banner shown while the realtime socket is down, with a
/// manual retry. Without it a message that cannot be sent looks merely slow;
/// with it the user learns the connection dropped and can reconnect.
///
/// Styled with the design system's `surface-container-high` tone and a hairline
/// divider so it reads as a status strip rather than an alert.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final socket = ref.watch(chatSocketProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ValueListenableBuilder<SocketStatus>(
      valueListenable: socket.connection,
      builder: (context, status, _) {
        if (status.isConnected) return const SizedBox.shrink();

        final connecting = status.isConnecting;
        return Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: connecting
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(Icons.cloud_off, size: 16, color: scheme.error),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  connecting ? 'Connecting…' : 'Reconnecting…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!connecting)
                TextButton(
                  onPressed: () => socket.connect(),
                  child: const Text('Reconnect'),
                ),
            ],
          ),
        );
      },
    );
  }
}
