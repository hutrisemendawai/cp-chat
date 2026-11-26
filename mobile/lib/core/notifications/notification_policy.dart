import '../crypto/e2ee_service.dart' show isEncryptedContent, undecryptableContent;
import '../media/media_service.dart' show splitMediaContent;

/// Formats a direct-chat peer display name consistently across foreground and
/// background notifications (`Name (nickname)` when a nickname is set).
String? formatDirectPeerLabel(String? name, String? nickname) {
  if (name == null || name.isEmpty) return null;
  final trimmedNick = nickname?.trim();
  if (trimmedNick == null || trimmedNick.isEmpty) return name;
  return '$name ($trimmedNick)';
}

/// Pure decision and formatting rules for incoming-message notifications.
///
/// Deliberately free of plugin and provider state so the suppression rules can
/// be unit-tested directly.
abstract final class NotificationPolicy {
  /// Whether an inbound message should raise a tray notification.
  ///
  /// Suppressed when it is the caller's own message, the caller is on Do Not
  /// Disturb, or the chat is open in the foreground (the user can already see
  /// it). Historical catch-up is excluded by the caller, not here, because only
  /// live frames reach this policy.
  static bool shouldNotify({
    String? senderId,
    required String? selfId,
    required String? selfStatus,
    required bool appResumed,
    required String? activeConversationId,
    required String conversationId,
  }) {
    if (senderId != null && (selfId == null || senderId == selfId)) return false;
    if (selfStatus == 'dnd') return false;
    if (appResumed && activeConversationId == conversationId) return false;
    return true;
  }

  /// The one-line body preview for a message.
  ///
  /// A body the client could not decrypt is reported as `Encrypted message`,
  /// never as its raw `e2ee:v1:` envelope.
  static String preview({required String type, required String content}) {
    if (type == 'image') {
      final caption = splitMediaContent(content).caption?.trim();
      return (caption != null && caption.isNotEmpty)
          ? 'Photo: $caption'
          : 'Sent an image';
    }
    if (type == 'file') {
      final caption = splitMediaContent(content).caption?.trim();
      return (caption != null && caption.isNotEmpty)
          ? 'File: $caption'
          : 'Sent a file';
    }
    if (isEncryptedContent(content) || content == undecryptableContent) {
      return 'Encrypted message';
    }
    final trimmed = content.trim();
    return trimmed.isEmpty ? 'New message' : trimmed;
  }

  /// Title and body for a message notification: the conversation name is the
  /// title, and a group body is prefixed with the sender so the thread is
  /// identifiable without opening it.
  static ({String title, String body}) format({
    required bool isGroup,
    required String conversationName,
    String? senderName,
    required String type,
    required String content,
  }) {
    final body = preview(type: type, content: content);
    if (!isGroup) return (title: conversationName, body: body);
    final who = senderName?.trim();
    return (
      title: conversationName,
      body: who == null || who.isEmpty ? body : '$who: $body',
    );
  }
}

/// A small time-bounded set of ids seen recently. Used to drop a notification
/// that both a live WebSocket message and an FCM push would otherwise raise.
class RecentIdSet {
  RecentIdSet({
    this.window = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final Map<String, DateTime> _seen = {};

  /// Records [id] and returns `true` when it is new (so the caller should
  /// notify), or `false` when it was already seen within [window].
  bool add(String id) {
    final current = _now();
    _seen.removeWhere((_, at) => current.difference(at) > window);
    final duplicate = _seen.containsKey(id);
    _seen[id] = current;
    return !duplicate;
  }

  void clear() => _seen.clear();
}
