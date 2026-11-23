import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../network/ws_client.dart';
import '../providers.dart';

/// A slim, non-blocking banner shown while the realtime socket is down, with a
/// manual retry. Without it a message that cannot be sent looks merely slow;
/// with it the user learns the connection dropped and can reconnect.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final socket = ref.watch(chatSocketProvider);
    final theme = Theme.of(context);

    return ValueListenableBuilder<SocketStatus>(
      valueListenable: socket.connection,
      builder: (context, status, _) {
        if (status.isConnected) return const SizedBox.shrink();

        final connecting = status.isConnecting;
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: connecting
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : Icon(Icons.cloud_off, size: 16, color: theme.colorScheme.error),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    connecting ? 'Connecting…' : 'Reconnecting…',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!connecting)
                  TextButton(
                    onPressed: () => socket.connect(),
                    child: const Text('Reconnect'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
