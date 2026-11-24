import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'database/app_database.dart';
import 'database/chat_dao.dart';
import 'crypto/e2ee_manager.dart';
import 'logging/app_logger.dart';
import 'media/media_service.dart';
import 'models/models.dart';
import 'network/api_client.dart';
import 'network/ws_client.dart';
import 'notifications/fcm_service.dart';
import 'notifications/push_registration.dart';
import 'storage/token_store.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final chatDaoProvider = Provider<ChatDao>((ref) {
  return ChatDao(ref.watch(appDatabaseProvider));
});

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

/// Client diagnostics with an in-memory ring buffer. Created before the network
/// stack so early failures can be recorded; the API client is attached to it
/// once constructed so `warn`/`error` entries can be forwarded to the server.
final appLoggerProvider = Provider<AppLogger>((ref) {
  final logger = AppLogger();
  ref.onDispose(logger.clear);
  return logger;
});

/// Stable per-install id, resolved during bootstrap. Immutable thereafter, so
/// the client that depends on it is rebuilt exactly once.
class DeviceIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String deviceId) => state = deviceId;
}

final deviceIdProvider =
    NotifierProvider<DeviceIdNotifier, String?>(DeviceIdNotifier.new);

final apiClientProvider = Provider<ApiClient>((ref) {
  final logger = ref.watch(appLoggerProvider);
  final api = ApiClient(
    ref.watch(tokenStoreProvider),
    deviceId: ref.watch(deviceIdProvider),
    logger: logger,
  );
  logger.attach(api);
  return api;
});

final mediaServiceProvider = Provider<MediaService>((ref) {
  return MediaService(
    ref.watch(apiClientProvider),
    logger: ref.watch(appLoggerProvider),
  );
});

/// End-to-end encryption for direct chats. Key material is generated lazily on
/// first use and stored in secure storage; only public keys reach the server.
final e2eeManagerProvider = Provider<E2eeManager>((ref) {
  return E2eeManager(
    tokenStore: ref.watch(tokenStoreProvider),
    api: ref.watch(apiClientProvider),
    logger: ref.watch(appLoggerProvider),
  );
});

/// The stored access token, exposed for widgets that fetch private media.
/// Rebuilds when the session changes so a rotated token is picked up.
final accessTokenProvider = FutureProvider<String?>((ref) async {
  ref.watch(authControllerProvider);
  return ref.watch(tokenStoreProvider).readAccessToken();
});

final chatSocketProvider = Provider<ChatSocket>((ref) {
  final socket = ChatSocket(
    ref.watch(chatDaoProvider),
    ref.watch(apiClientProvider),
    ref.watch(tokenStoreProvider),
    logger: ref.watch(appLoggerProvider),
    decrypt: (conversationId, clientMsgId, senderId, content, {required isGroup}) {
      return ref.read(e2eeManagerProvider).plaintextFor(
            clientMsgId,
            conversationId,
            content,
            isGroup: isGroup,
            senderId: senderId,
          );
    },
  );
  ref.onDispose(socket.dispose);
  return socket;
});

/// Registers this install for push delivery while a session is active.
final pushRegistrationProvider = Provider<PushRegistration>((ref) {
  final registration = PushRegistration(ref.watch(apiClientProvider));
  ref.onDispose(() => unawaited(registration.stop()));
  return registration;
});

/// Owns the realtime session lifecycle: it boots the E2EE keys, connects the
/// chat socket, and starts push registration, then tears all three down on
/// logout.
///
/// It lives in its own provider (rather than inside [SessionRuntime]) so an
/// explicit `logout()` can stop the session without reading `sessionRuntime`,
/// which listens to the auth controller and would otherwise form a circular
/// dependency. `stop()` is a no-op unless a session is running, so the
/// auth-transition listener firing after an explicit `logout()` does not start a
/// second teardown.
class SessionLifecycle {
  SessionLifecycle(this._ref);

  final Ref _ref;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _running = false;

  /// Starts the socket and push registration for the active session. Safe to
  /// call repeatedly: a run already in flight is awaited rather than duplicated,
  /// and a cold-start restore and the login listener share one boot.
  Future<void> start() async {
    if (_ref.read(authControllerProvider) == null) return;
    _running = true;
    final existing = _starting;
    if (existing != null) return existing;
    final run = _start();
    _starting = run;
    try {
      await run;
    } finally {
      if (identical(_starting, run)) _starting = null;
    }
  }

  Future<void> _start() async {
    // Encryption keys must be ready before the first inbound frame is decrypted
    // and before the outbox is flushed, so bootstrap them first.
    try {
      await _ref.read(e2eeManagerProvider).bootstrap();
    } catch (error) {
      debugPrint('E2EE bootstrap failed: $error');
    }

    await _ref.read(chatSocketProvider).connect();

    await _ref.read(pushRegistrationProvider).start();
  }

  /// Stops realtime work on logout. An in-flight boot is awaited first so a late
  /// connect cannot revive a socket that is being torn down, then each step is
  /// individually guarded so a stalled socket cannot block the rest.
  Future<void> stop() {
    final existing = _stopping;
    if (existing != null) return existing;
    if (!_running) return Future<void>.value();
    _running = false;
    final run = _stop();
    _stopping = run;
    return run.whenComplete(() {
      if (identical(_stopping, run)) _stopping = null;
    });
  }

  Future<void> _stop() async {
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (error) {
        debugPrint('Session stop awaiting boot failed: $error');
      }
    }
    try {
      await _ref.read(chatSocketProvider).disconnect();
    } catch (error) {
      debugPrint('Session teardown socket disconnect failed: $error');
    }
    try {
      await _ref.read(pushRegistrationProvider).stop();
    } catch (error) {
      debugPrint('Session teardown push stop failed: $error');
    }
    _ref.read(e2eeManagerProvider).reset();
  }
}

final sessionLifecycleProvider = Provider<SessionLifecycle>(SessionLifecycle.new);

/// Watches the auth state and drives [SessionLifecycle] so session transitions
/// are handled in one place and cannot be missed: `ref.listen` inside a
/// lifecycle method is not permitted, and a boot that ran only once would never
/// react to a manual login.
class SessionRuntime extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<AuthSession?>(authControllerProvider, (previous, next) {
      final lifecycle = ref.read(sessionLifecycleProvider);
      if (next != null) {
        unawaited(lifecycle.start());
      } else {
        unawaited(lifecycle.stop());
      }
    });
    return false;
  }

  Future<void> start() => ref.read(sessionLifecycleProvider).start();

  Future<void> stop() => ref.read(sessionLifecycleProvider).stop();
}

final sessionRuntimeProvider =
    NotifierProvider<SessionRuntime, bool>(SessionRuntime.new);

/// Resolves the device id and boots push registration before the app renders.
final bootstrapProvider = FutureProvider<void>((ref) async {
  final tokenStore = ref.watch(tokenStoreProvider);
  var deviceId = await tokenStore.readDeviceId();
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await tokenStore.writeDeviceId(deviceId);
  }
  ref.read(deviceIdProvider.notifier).set(deviceId);

  await FcmService.initialize();
});

/// The authenticated session. `null` means signed out.
class AuthController extends Notifier<AuthSession?> {
  @override
  AuthSession? build() => null;

  Future<void> login({required String phoneOrEmail, required String password}) async {
    final session = await ref.read(apiClientProvider).login(
          phoneOrEmail: phoneOrEmail,
          password: password,
        );
    state = session;
  }

  Future<void> register({
    required String phoneOrEmail,
    required String name,
    required String password,
  }) async {
    final session = await ref.read(apiClientProvider).register(
          phoneOrEmail: phoneOrEmail,
          name: name,
          password: password,
        );
    state = session;
  }

  /// Restores a persisted session on cold start.
  Future<void> restore() async {
    final tokenStore = ref.read(tokenStoreProvider);
    if (!await tokenStore.hasSession()) return;
    try {
      final user = await ref.read(apiClientProvider).me();
      final access = await tokenStore.readAccessToken();
      final refresh = await tokenStore.readRefreshToken();
      if (access == null || refresh == null) return;
      state = AuthSession(
        user: user,
        accessToken: access,
        refreshToken: refresh,
        expiresIn: 0,
      );
    } catch (error) {
      debugPrint('Session restore failed: $error');
      await tokenStore.clear();
    }
  }

  /// Upper bound on each logout teardown step. A step that overruns it is
  /// abandoned (its work continues in the background) so signing out always
  /// reaches the signed-out state instead of hanging on a stalled socket or an
  /// unreachable server.
  Duration logoutStepTimeout = const Duration(seconds: 5);

  Future<void> logout() async {
    final api = ref.read(apiClientProvider);
    final chatDao = ref.read(chatDaoProvider);
    try {
      // Tear down the socket before clearing tokens so it stops reconnecting
      // with a session that is about to disappear, and reset E2EE state so a
      // different account signing in next cannot see the previous account's
      // plaintext.
      try {
        await ref.read(sessionLifecycleProvider).stop().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout teardown failed: $error');
      }
      try {
        await api.logout().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout API call failed: $error');
      }
      try {
        await chatDao.clearAll().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout local clear failed: $error');
      }
    } finally {
      // Always clear the session locally, even if a step stalled, so the router
      // can redirect to /auth instead of leaving the user on a dead session.
      state = null;
    }
  }

  /// Replaces the cached user after a profile edit so every screen reading
  /// [currentUserProvider] (chat list avatar, headers) refreshes immediately,
  /// without ending the session or re-fetching.
  void applyUser(User user) {
    final current = state;
    if (current == null) return;
    state = AuthSession(
      user: user,
      accessToken: current.accessToken,
      refreshToken: current.refreshToken,
      expiresIn: current.expiresIn,
    );
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthSession?>(AuthController.new);

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authControllerProvider)?.user;
});

/// The chat list, backed by the local mirror.
final conversationsProvider = StreamProvider<List<LocalConversation>>((ref) {
  return ref.watch(chatDaoProvider).watchConversations();
});

/// Messages for one conversation, backed by the local mirror.
final messagesProvider =
    StreamProvider.family<List<LocalMessage>, String>((ref, conversationId) {
  return ref.watch(chatDaoProvider).watchMessages(conversationId);
});
