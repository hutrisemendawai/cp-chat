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
  });

  final String conversationId;
  final String? accountId;

  /// Encodes as `{"a":"<accountId>","c":"<conversationId>"}` (or bare `{"c":...}`
  /// when no account id is known).
  String encode() => jsonEncode({
        if (accountId != null && accountId!.isNotEmpty) 'a': accountId,
        'c': conversationId,
      });

  /// Parses either the account-tagged JSON format or a legacy bare
  /// `conversationId` string. Returns `null` for empty/unparseable payloads.
  static NotificationTapTarget? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          final conv = decoded['c']?.toString() ?? '';
          if (conv.isEmpty) return null;
          final acct = decoded['a']?.toString();
          return NotificationTapTarget(
            conversationId: conv,
            accountId: (acct == null || acct.isEmpty) ? null : acct,
          );
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    return NotificationTapTarget(conversationId: trimmed);
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

  Future<void> initialize() async {
    if (_initialized) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: 'Incoming chat messages',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final parsed = NotificationTapTarget.parse(launch?.notificationResponse?.payload);
      if (parsed != null) {
        _coldStartTarget = parsed;
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
    final parsed = NotificationTapTarget.parse(response.payload);
    if (parsed == null) return;
    _tapTargets.add(parsed);
    _taps.add(parsed.conversationId);
  }

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
