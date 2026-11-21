import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// Presence for one user: the REST snapshot on open, then live `presence`
/// frames pushed by the gateway. Rebuilds whenever either source updates.
class PresenceNotifier extends Notifier<Presence?> {
  PresenceNotifier(this.userId);

  final String userId;

  StreamSubscription<Presence>? _subscription;

  @override
  Presence? build() {
    final socket = ref.watch(chatSocketProvider);
    _subscription?.cancel();
    _subscription = socket.presenceEvents
        .where((event) => event.userId == userId)
        .listen((event) => state = event);
    ref.onDispose(() => _subscription?.cancel());

    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final snapshot = await ref.read(apiClientProvider).presence(userId);
      // A live frame may have landed first; prefer whichever is newer.
      final current = state;
      if (current == null || _isNewer(snapshot, current)) {
        state = snapshot;
      }
    } catch (_) {
      // Presence is best-effort; a failure just leaves the header neutral.
    }
  }

  bool _isNewer(Presence candidate, Presence current) {
    if (candidate.online != current.online) return true;
    final next = candidate.lastSeenAt;
    final previous = current.lastSeenAt;
    if (next == null) return false;
    if (previous == null) return true;
    return next.isAfter(previous);
  }
}

final presenceProvider =
    NotifierProvider.family<PresenceNotifier, Presence?, String>(PresenceNotifier.new);

/// "Online", "Last seen 5m ago", or nothing while unknown.
String? formatPresence(Presence? presence, {DateTime? now}) {
  if (presence == null) return null;
  if (presence.online) return 'Online';

  final lastSeen = presence.lastSeenAt;
  if (lastSeen == null) return 'Offline';

  final reference = now ?? DateTime.now();
  final difference = reference.difference(lastSeen.toLocal());
  if (difference.inMinutes < 1) return 'Last seen just now';
  if (difference.inMinutes < 60) return 'Last seen ${difference.inMinutes}m ago';
  if (difference.inHours < 24) return 'Last seen ${difference.inHours}h ago';
  if (difference.inDays < 7) return 'Last seen ${difference.inDays}d ago';
  return 'Last seen ${lastSeen.toLocal().day}/${lastSeen.toLocal().month}';
}
