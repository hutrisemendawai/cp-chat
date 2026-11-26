import '../models/models.dart';
import 'local_notification_service.dart';
import 'notification_policy.dart';

/// Conversation display info resolved from the local mirror when a message
/// arrives: whether it is a group and the name to use as the notification
/// title.
typedef ConversationNames = ({bool isGroup, String displayName});

/// Decides whether a live message raises a local notification and, if so,
/// renders and shows it.
///
/// All app state (current user, presence, lifecycle, active chat) is read
/// through callbacks rather than Riverpod so the whole flow can be exercised
/// with a fake sink in a unit test.
class MessageNotifier {
  MessageNotifier({
    required this.notifications,
    required this.selfId,
    required this.selfStatus,
    required this.appResumed,
    required this.activeConversationId,
    required this.resolveNames,
    this.accountId,
    Duration dedupeWindow = const Duration(seconds: 60),
  }) : _recent = RecentIdSet(window: dedupeWindow);

  final MessageNotificationSink notifications;
  final String? Function() selfId;
  final String? Function() selfStatus;
  final bool Function() appResumed;
  final String? Function() activeConversationId;
  final Future<ConversationNames?> Function(String conversationId) resolveNames;
  final String? Function()? accountId;
  final RecentIdSet _recent;

  /// Clears recent deduplication history (called on logout).
  void reset() {
    _recent.clear();
  }

  /// A live WebSocket message, already decrypted and persisted. Silent when
  /// [NotificationPolicy] suppresses it or the same message was shown recently.
  Future<void> onLiveMessage(Message message, {String? senderName}) async {
    if (!_shouldNotify(senderId: message.senderId, conversationId: message.conversationId)) {
      return;
    }
    if (!_recent.add(message.id)) return;

    final names = await resolveNames(message.conversationId);
    final rendered = NotificationPolicy.format(
      isGroup: names?.isGroup ?? false,
      conversationName: names?.displayName ?? senderName ?? 'New message',
      senderName: senderName,
      type: message.type,
      content: message.content,
    );
    await notifications.showMessageNotification(
      conversationId: message.conversationId,
      title: rendered.title,
      body: rendered.body,
      messageId: message.id,
      accountId: accountId?.call(),
    );
  }

  /// A foreground FCM push. The backend already titles and redacts the payload,
  /// so only the local suppression and dedupe rules still apply.
  Future<void> onForegroundFcm({
    required String conversationId,
    required String messageId,
    required String title,
    required String body,
  }) async {
    if (!_shouldNotify(senderId: null, conversationId: conversationId)) return;
    if (!_recent.add(messageId)) return;
    await notifications.showMessageNotification(
      conversationId: conversationId,
      title: title,
      body: body,
      messageId: messageId,
      accountId: accountId?.call(),
    );
  }

  bool _shouldNotify({String? senderId, required String conversationId}) =>
      NotificationPolicy.shouldNotify(
        senderId: senderId,
        selfId: selfId(),
        selfStatus: selfStatus(),
        appResumed: appResumed(),
        activeConversationId: activeConversationId(),
        conversationId: conversationId,
      );
}
