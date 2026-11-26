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
    ref.watch(accountScopeProvider);
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
    if (candidate.resolvedStatus != current.resolvedStatus) return true;
    if (candidate.customStatus != current.customStatus) return true;
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

/// Human label for a Discord-style status, used by the selector and badges.
String statusLabel(String status) {
  switch (status) {
    case 'online':
      return 'Online';
    case 'idle':
      return 'Idle';
    case 'dnd':
      return 'Do Not Disturb';
    case 'offline':
    case 'invisible':
      return 'Invisible';
    default:
      return 'Offline';
  }
}

/// Secondary header line: a live status label, or a relative last-seen time.
///
/// A custom status takes precedence while the user is visible, so a chat header
/// can show "Online · Building things". An invisible or offline user never
/// reveals a status label.
String? formatPresence(Presence? presence, {DateTime? now}) {
  if (presence == null) return null;

  final label = switch (presence.resolvedStatus) {
    'online' => 'Online',
    'idle' => 'Idle',
    'dnd' => 'Do Not Disturb',
    _ => null,
  };

  if (label != null) {
    final custom = presence.customStatus?.trim();
    if (custom != null && custom.isNotEmpty) return '$label · $custom';
    return label;
  }

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
