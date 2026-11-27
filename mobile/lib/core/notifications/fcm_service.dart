import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import '../account/account_id.dart';
import '../logging/app_logger.dart';
import '../storage/token_store.dart';
import 'background_push_handler.dart';

/// The tray content derived from an FCM payload.
typedef FcmNotificationContent = ({
  String conversationId,
  String title,
  String body,
  String? messageId,
  String? recipientUserId,
});

/// Maps a push to tray content, or `null` when it carries no conversation to
/// route to. The body falls back to `New message` because the headless isolate
/// cannot run E2EE decryption, and it never carries ciphertext.
FcmNotificationContent? notificationContentFromFcm(RemoteMessage message) {
  final conversationId = message.data['conversation_id']?.toString() ?? '';
  if (conversationId.isEmpty) return null;
  final senderName = message.data['sender_name']?.toString();
  final recipientUserId = message.data['recipient_user_id']?.toString();
  return (
    conversationId: conversationId,
    title: message.notification?.title ?? senderName ?? 'New message',
    body: message.notification?.body ?? 'New message',
    messageId: message.data['message_id']?.toString(),
    recipientUserId:
        (recipientUserId == null || recipientUserId.isEmpty) ? null : recipientUserId,
  );
}

/// Returns `true` when an FCM payload is allowed to be shown or routed for the
/// currently signed-in account.
///
/// Drops notifications whenever there is no active session or when
/// [recipientUserId] hashes to a different account than [activeAccountId] (§3.3).
bool shouldHandleFcmForAccount({
  required String? recipientUserId,
  required String? activeAccountId,
  required bool hasSession,
}) {
  if (!hasSession || activeAccountId == null || activeAccountId.isEmpty) {
    return false;
  }
  if (recipientUserId != null && recipientUserId.isNotEmpty) {
    return accountIdForUser(recipientUserId) == activeAccountId;
  }
  return true;
}

/// Evaluates whether the headless FCM handler should display [message] against
/// [tokenStore] without ever opening SQLite. Exposed for unit testing (§3.3).
Future<({FcmNotificationContent content, String accountId})?>
    resolveHeadlessFcmDisplay(
  RemoteMessage message, {
  TokenStore? tokenStore,
}) async {
  if (message.notification != null) return null;
  final content = notificationContentFromFcm(message);
  if (content == null) return null;

  final store = tokenStore ?? TokenStore();
  final access = await store.readAccessToken();
  final refresh = await store.readRefreshToken();
  final hasSession = access != null || refresh != null;
  var activeAccountId = await store.readActiveAccountId();
  if (activeAccountId == null) {
    final userId = await store.readUserId();
    if (userId != null && userId.isNotEmpty) {
      activeAccountId = accountIdForUser(userId);
    }
  }

  if (!shouldHandleFcmForAccount(
    recipientUserId: content.recipientUserId,
    activeAccountId: activeAccountId,
    hasSession: hasSession,
  )) {
    return null;
  }

  return (content: content, accountId: activeAccountId!);
}

/// Runs in a headless isolate when a high-priority data-only push arrives while
/// the app is backgrounded or terminated.
///
/// Delegates to [BackgroundPushHandler.shared], which forwards to the live main
/// isolate via `IsolateNameServer` if the app is still in memory, or otherwise
/// acquires the per-account `.partition.lock`, decrypts the E2EE payload using
/// `TokenStore.forBackground()` (`resetOnError: false`), persists plaintext to
/// the canonical account SQLite DB before advancing persisted ratchet sessions,
/// and raises a local notification with the real message preview.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('Background Firebase.initializeApp skipped: $error');
  }
  await BackgroundPushHandler.shared.handle(message);
}

/// Firebase Cloud Messaging bootstrap.
abstract final class FcmService {
  static bool _initialized = false;
  static String? _cachedFid;
  static StreamSubscription<String>? _registeredSub;
  static final StreamController<String> _fidController =
      StreamController<String>.broadcast();
  static AppLogger? _logger;

  static Future<void> initialize({AppLogger? logger}) async {
    if (logger != null) _logger = logger;
    if (_initialized) return;
    try {
      await Firebase.initializeApp();
      _initialized = true;
      _registeredSub ??= FirebaseMessaging.instance.onRegistered.listen((fid) {
        if (fid.isEmpty) return;
        _cachedFid = fid;
        _fidController.add(fid);
      });
      try {
        await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (_) {}
      _logger?.info('fcm', 'FCM initialized');
    } catch (error) {
      final message =
          'FCM unavailable: Firebase is not configured '
          '(missing google-services.json or invalid options): $error';
      if (_logger != null) {
        _logger!.warn('fcm', message, meta: {'error': error.toString()});
      } else {
        debugPrint(message);
      }
      _initialized = false;
    }
  }

  static bool get isAvailable => _initialized;

  static Future<String?> currentToken() async {
    if (!_initialized) return null;
    if (_cachedFid != null && _cachedFid!.isNotEmpty) {
      unawaited(FirebaseMessaging.instance.register().catchError((_) {}));
      return _cachedFid;
    }
    try {
      final registered = _fidController.stream.first;
      await FirebaseMessaging.instance.register();
      final fid = await registered.timeout(const Duration(seconds: 10));
      _cachedFid = fid;
      return fid;
    } catch (error) {
      if (_logger != null) {
        _logger!.warn(
          'fcm',
          'FCM registration unavailable',
          meta: {'error': error.toString()},
        );
      } else {
        debugPrint('FCM registration unavailable: $error');
      }
      return null;
    }
  }

  static Stream<String> get onTokenRefresh =>
      _initialized ? _fidController.stream : const Stream<String>.empty();

  static Stream<RemoteMessage> get onNotificationTap =>
      FirebaseMessaging.onMessageOpenedApp;

  static Stream<RemoteMessage> get onForegroundMessage => FirebaseMessaging.onMessage;

  static Future<RemoteMessage?> initialMessage() =>
      FirebaseMessaging.instance.getInitialMessage();
}
