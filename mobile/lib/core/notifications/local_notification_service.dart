import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Parsed tap target carried by a local notification payload.
@immutable
class NotificationTapTarget {
  const NotificationTapTarget({
    required this.conversationId,
    this.accountId,
    this.kind = 'message',
    this.callId,
    this.callerId,
    this.callerName,
    this.mediaType,
    this.expiresAtMs,
    this.actionId,
  });

  final String conversationId;
  final String? accountId;
  final String kind;
  final String? callId;
  final String? callerId;
  final String? callerName;
  final String? mediaType;
  final int? expiresAtMs;
  final String? actionId;

  bool get isCall => kind == 'call' && callId != null && callId!.isNotEmpty;

  NotificationTapTarget copyWith({String? actionId}) {
    return NotificationTapTarget(
      conversationId: conversationId,
      accountId: accountId,
      kind: kind,
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      mediaType: mediaType,
      expiresAtMs: expiresAtMs,
      actionId: actionId ?? this.actionId,
    );
  }

  /// Encodes as `{"a":"<accountId>","c":"<conversationId>"}` (plus optional
  /// call metadata when `kind == 'call'`).
  String encode() => jsonEncode({
        if (accountId != null && accountId!.isNotEmpty) 'a': accountId,
        'c': conversationId,
        if (kind != 'message') 'k': kind,
        if (callId != null && callId!.isNotEmpty) 'call_id': callId,
        if (callerId != null && callerId!.isNotEmpty) 'caller_id': callerId,
        if (callerName != null && callerName!.isNotEmpty)
          'caller_name': callerName,
        if (mediaType != null && mediaType!.isNotEmpty) 'media_type': mediaType,
        if (expiresAtMs != null) 'expires_at': expiresAtMs,
      });

  /// Parses either the account-tagged JSON format or a legacy bare
  /// `conversationId` string. Returns `null` for empty/unparseable payloads.
  static NotificationTapTarget? parse(String? raw, {String? actionId}) {
    if (raw == null || raw.isEmpty) return null;
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          final conv = decoded['c']?.toString() ?? '';
          if (conv.isEmpty) return null;
          final acct = decoded['a']?.toString();
          final kind = decoded['k']?.toString() ?? 'message';
          final expRaw = decoded['expires_at'];
          final expiresAtMs = expRaw is num
              ? expRaw.toInt()
              : int.tryParse(expRaw?.toString() ?? '');
          return NotificationTapTarget(
            conversationId: conv,
            accountId: (acct == null || acct.isEmpty) ? null : acct,
            kind: kind,
            callId: decoded['call_id']?.toString(),
            callerId: decoded['caller_id']?.toString(),
            callerName: decoded['caller_name']?.toString(),
            mediaType: decoded['media_type']?.toString(),
            expiresAtMs: expiresAtMs,
            actionId: (actionId == null || actionId.isEmpty) ? null : actionId,
          );
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    return NotificationTapTarget(conversationId: trimmed, actionId: actionId);
  }

  /// Returns `true` when this tap target belongs to the currently active
  /// signed-in account. Foreign-account payloads and payloads with no active
  /// session return `false`.
  bool matchesActiveAccount(String? activeAccountId) {
    if (activeAccountId == null || activeAccountId.isEmpty) return false;
    if (accountId == null || accountId!.isEmpty) return false;
    return accountId == activeAccountId;
  }
}

/// Where a message notification is delivered. The [MessageNotifier] depends on
/// this instead of the plugin directly so its rules stay unit-testable.
abstract class MessageNotificationSink {
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
    String? accountId,
  });
}

/// Android notification-tray integration for incoming messages.
///
/// Every local notification carries an account-tagged payload `{"a","c"}`,
/// a notification id hashed from `(accountId, conversationId)`, and Android
/// `tag` / `groupKey` set to `accountId` so notifications can be cancelled per
/// account and taps from a signed-out account are dropped.
class LocalNotificationService implements MessageNotificationSink {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// High-importance channel. The backend's default FCM channel targets the
  /// same id so a background push and a foreground banner look identical.
  static const String channelId = 'cpchat_messages';
  static const String channelName = 'Messages';
  static const String callChannelId = 'cpchat_calls';
  static const String callChannelName = 'Incoming Calls';
  static const String actionCallAccept = 'call_accept';
  static const String actionCallDecline = 'call_decline';

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController<String>.broadcast();
  final StreamController<NotificationTapTarget> _tapTargets =
      StreamController<NotificationTapTarget>.broadcast();

  /// Tracks notification ids shown per account so `cancelForAccount` can clear
  /// only that account's notifications.
  final Map<String, Set<int>> _shownIdsByAccount = {};

  bool _initialized = false;
  NotificationTapTarget? _coldStartTarget;

  /// Emits the `conversation_id` of a tapped notification.
  Stream<String> get onNotificationTap => _taps.stream;

  /// Emits the full account-tagged tap target of a tapped notification.
  Stream<NotificationTapTarget> get onNotificationTapTarget => _tapTargets.stream;

  /// The full tap target that cold-started the app, if any.
  NotificationTapTarget? get coldStartTarget => _coldStartTarget;

  /// The `conversation_id` of the notification that cold-started the app, if
  /// any. Prefer [coldStartTarget] to verify account ownership first.
  String? get coldStartConversationId => _coldStartTarget?.conversationId;

  /// Clears any stored cold-start notification intent (e.g. after consuming or
  /// dropping a foreign-account intent).
  void clearColdStart() {
    _coldStartTarget = null;
  }

  Future<void> initialize({bool checkLaunchDetails = true}) async {
    if (_initialized) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: 'Incoming chat messages',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        enableLights: true,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        callChannelId,
        callChannelName,
        description: 'Incoming voice and video calls',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        enableLights: true,
      ),
    );

    if (checkLaunchDetails) {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        final parsed = NotificationTapTarget.parse(
          launch?.notificationResponse?.payload,
          actionId: launch?.notificationResponse?.actionId,
        );
        if (parsed != null) {
          _coldStartTarget = parsed;
        }
      }
    }
    _initialized = true;
  }

  Future<void> requestPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }

  @override
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
    String? messageId,
    String? accountId,
  }) async {
    if (!_initialized) return;
    final id = notificationIdFor(conversationId, accountId: accountId);
    final target = NotificationTapTarget(
      conversationId: conversationId,
      accountId: accountId,
    );
    if (accountId != null && accountId.isNotEmpty) {
      (_shownIdsByAccount[accountId] ??= <int>{}).add(id);
    }
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Incoming chat messages',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          tag: accountId,
          groupKey: accountId,
        ),
      ),
      payload: target.encode(),
    );
  }

  /// Shows a high-priority full-screen incoming call notification with Accept
  /// and Decline actions so locked / backgrounded / terminated devices ring.
  Future<void> showIncomingCallNotification({
    required String callId,
    required String conversationId,
    required String callerId,
    required String callerName,
    required String mediaType,
    String? accountId,
    int? expiresAtMs,
  }) async {
    if (!_initialized) return;
    final id = callNotificationIdFor(callId);
    final target = NotificationTapTarget(
      conversationId: conversationId,
      accountId: accountId,
      kind: 'call',
      callId: callId,
      callerId: callerId,
      callerName: callerName,
      mediaType: mediaType,
      expiresAtMs: expiresAtMs,
    );
    if (accountId != null && accountId.isNotEmpty) {
      (_shownIdsByAccount[accountId] ??= <int>{}).add(id);
    }
    final isVideo = mediaType == 'video';
    await _plugin.show(
      id: id,
      title: callerName,
      body: isVideo ? 'Incoming video call' : 'Incoming voice call',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          callChannelId,
          callChannelName,
          channelDescription: 'Incoming voice and video calls',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          visibility: NotificationVisibility.public,
          tag: 'call:$callId',
          actions: const [
            AndroidNotificationAction(
              actionCallAccept,
              'Accept',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              actionCallDecline,
              'Decline',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: target.encode(),
    );
  }

  /// Dismisses an incoming call notification immediately (cancel/timeout/answered elsewhere).
  Future<void> cancelCallNotification(String callId) async {
    if (!_initialized || callId.isEmpty) return;
    await _plugin.cancel(id: callNotificationIdFor(callId), tag: 'call:$callId');
  }

  /// Clears the notification shown for one conversation (its chat was opened).
  Future<void> cancelForConversation(
    String conversationId, {
    String? accountId,
  }) async {
    if (!_initialized) return;
    final id = notificationIdFor(conversationId, accountId: accountId);
    await _plugin.cancel(id: id, tag: accountId);
    if (accountId != null) {
      _shownIdsByAccount[accountId]?.remove(id);
    }
  }

  /// Clears every notification shown for [accountId], plus `cancelAll()`
  /// fallback so OS-painted FCM banners for that account never leak across
  /// sign-out.
  Future<void> cancelForAccount(String accountId) async {
    final ids = _shownIdsByAccount.remove(accountId);
    if (!_initialized) return;
    if (ids != null) {
      for (final id in ids) {
        await _plugin.cancel(id: id, tag: accountId);
      }
    }
    // Also clear any OS-painted FCM notifications that bypassed this service.
    await _plugin.cancelAll();
  }

  /// Clears every notification not belonging to [activeAccountId] on login.
  Future<void> cancelForeignAccounts(String activeAccountId) async {
    final foreign = _shownIdsByAccount.keys
        .where((key) => key != activeAccountId)
        .toList();
    for (final accountId in foreign) {
      final ids = _shownIdsByAccount.remove(accountId) ?? const <int>{};
      if (_initialized) {
        for (final id in ids) {
          await _plugin.cancel(id: id, tag: accountId);
        }
      }
    }
    if (_coldStartTarget != null &&
        !_coldStartTarget!.matchesActiveAccount(activeAccountId)) {
      _coldStartTarget = null;
    }
  }

  /// Clears every notification (on sign-out fallback).
  Future<void> cancelAll() async {
    _shownIdsByAccount.clear();
    _coldStartTarget = null;
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  void _onResponse(NotificationResponse response) {
    final parsed = NotificationTapTarget.parse(
      response.payload,
      actionId: response.actionId,
    );
    if (parsed == null) return;
    _tapTargets.add(parsed);
    if (!parsed.isCall) {
      _taps.add(parsed.conversationId);
    }
  }

  static int callNotificationIdFor(String callId) =>
      ('call:$callId'.hashCode & 0x7fffffff);

  /// Stable notification id hashed from `(accountId, conversationId)` so
  /// banners for different accounts never collide.
  static int notificationIdFor(String conversationId, {String? accountId}) {
    final key = (accountId == null || accountId.isEmpty)
        ? conversationId
        : '$accountId:$conversationId';
    return key.hashCode & 0x7fffffff;
  }

  Future<void> dispose() async {
    await _tapTargets.close();
    await _taps.close();
  }
}
