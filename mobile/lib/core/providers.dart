import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'account/account_id.dart';
import 'account/account_paths.dart';
import 'account/account_registry.dart';
import 'account/account_scope.dart';
import 'account/account_store.dart';
import 'account/account_wiper.dart';
import 'account/legacy_migration.dart';
import 'account/partition_guard.dart';
import 'account/partition_lock.dart';
import 'crypto/e2ee_manager.dart';
import 'database/app_database.dart';
import 'database/chat_dao.dart';
import 'logging/app_logger.dart';
import 'media/account_media_cache.dart';
import 'media/media_service.dart';
import 'models/models.dart';
import 'network/api_client.dart';
import 'network/ws_client.dart';
import 'notifications/background_push_handler.dart';
import 'notifications/crash_reporter.dart';
import 'notifications/fcm_service.dart';
import 'notifications/local_notification_service.dart';
import 'notifications/message_notifier.dart';
import 'notifications/notification_policy.dart';
import 'notifications/push_registration.dart';
import 'storage/app_dirs.dart';
import 'storage/token_store.dart';
import '../features/chat/conversation_metadata.dart';

int _nextScopeEpoch = 0;

// ---------------------------------------------------------------------------
// Device-global providers (survive account switches)
// ---------------------------------------------------------------------------

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final appDirsProvider = Provider<AppDirs>((ref) => AppDirs());

final dbGateProvider = Provider<DbGate>((ref) => DbGate());

class BootstrapTracker {
  Future<void>? inFlight;
}

final bootstrapTrackerProvider = Provider<BootstrapTracker>((ref) => BootstrapTracker());

final accountRegistryProvider = Provider<AccountRegistry>((ref) {
  return AccountRegistry(ref.watch(tokenStoreProvider));
});

final legacyMigrationProvider = Provider<LegacyMigration>((ref) {
  return LegacyMigration(
    tokenStore: ref.watch(tokenStoreProvider),
    dirs: ref.watch(appDirsProvider),
    registry: ref.watch(accountRegistryProvider),
    logger: ref.watch(appLoggerProvider),
  );
});

final accountWiperProvider = Provider<AccountWiper>((ref) {
  return AccountWiper(
    tokenStore: ref.watch(tokenStoreProvider),
    dirs: ref.watch(appDirsProvider),
    registry: ref.watch(accountRegistryProvider),
    dbGate: ref.watch(dbGateProvider),
    logger: ref.watch(appLoggerProvider),
  );
});

/// Client diagnostics with an in-memory ring buffer. Cleared automatically on
/// account switches so logs from one account never bleed into another.
final appLoggerProvider = Provider<AppLogger>((ref) {
  final logger = AppLogger();
  ref.onDispose(logger.clear);
  return logger;
});

/// Stable per-install id, resolved during bootstrap. Immutable thereafter, so
/// the client that depends on it is rebuilt exactly once.
class DeviceIdNotifier extends Notifier<String?> {
  // ignore: prefer_initializing_formals
  DeviceIdNotifier({String? initial}) : _initial = initial;

  final String? _initial;

  @override
  String? build() => _initial;

  void set(String deviceId) => state = deviceId;
}

final deviceIdProvider =
    NotifierProvider<DeviceIdNotifier, String?>(DeviceIdNotifier.new);

/// Android notification-tray integration for incoming messages.
final localNotificationServiceProvider = Provider<LocalNotificationService>((ref) {
  final service = LocalNotificationService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// The app's current lifecycle state, tracking whether it is in the foreground
/// so a notification for the chat already on screen can be suppressed.
class AppLifecycleNotifier extends Notifier<AppLifecycleState> {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;

  void set(AppLifecycleState state) => this.state = state;
}

final appLifecycleProvider =
    NotifierProvider<AppLifecycleNotifier, AppLifecycleState>(AppLifecycleNotifier.new);

// ---------------------------------------------------------------------------
// Account identity & scope boundary
// ---------------------------------------------------------------------------

/// Root account-identity notifier driven by [AuthController] transitions.
///
/// Kept independent of `authControllerProvider` so the provider graph stays
/// strictly acyclic in Riverpod 3: [AuthController] can read account-scoped
/// services during teardown without forming a circular dependency, while every
/// user-bound provider watches [accountScopeProvider] (which watches this).
class ActiveAccountUserIdNotifier extends Notifier<String?> {
  // ignore: prefer_initializing_formals
  ActiveAccountUserIdNotifier({String? initial}) : _initial = initial;

  final String? _initial;

  @override
  String? build() => _initial;

  void set(String? userId) {
    if (state == userId) return;
    state = userId;
  }
}

final activeAccountUserIdProvider =
    NotifierProvider<ActiveAccountUserIdNotifier, String?>(
  ActiveAccountUserIdNotifier.new,
);

/// Stable user id of the currently authenticated session.
///
/// Token rotations and profile edits keep the same user id, so they do NOT
/// rebuild [accountScopeProvider] or reopen the local database.
final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(activeAccountUserIdProvider);
});

/// Active account partition scope. Rebuilds ONLY when the signed-in user id
/// changes (login, logout, or account switch). Every user-bound provider
/// watches this provider so switching accounts cleanly disposes the entire
/// previous graph (§2.2).
final accountScopeProvider = Provider<AccountScope?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;

  final logger = ref.read(appLoggerProvider);
  final scope = AccountScope(
    accountId: accountIdForUser(userId),
    userId: userId,
    epoch: ++_nextScopeEpoch,
  );
  ref.onDispose(() {
    scope.beginClose();
    logger.clear();
    evictMemoryImageCache();
  });
  return scope;
});

final accountStoreProvider = Provider<AccountStore?>((ref) {
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  return AccountStore(ref.watch(tokenStoreProvider), scope.accountId);
});

final accountPathsProvider = FutureProvider<AccountPaths?>((ref) async {
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  return AccountPaths.resolve(scope.accountId, ref.watch(appDirsProvider));
});

/// Tracks whether the one-time D1 prompt ("Start fresh" vs "Keep group history")
/// should be displayed after a fresh-partition login with existing group chats.
class FreshPartitionPromptNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(accountScopeProvider);
    return false;
  }

  void show() => state = true;
  void dismiss() => state = false;
}

final freshPartitionPromptProvider =
    NotifierProvider<FreshPartitionPromptNotifier, bool>(
  FreshPartitionPromptNotifier.new,
);

// ---------------------------------------------------------------------------
// Account-scoped providers (all watch accountScopeProvider)
// ---------------------------------------------------------------------------

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final scope = ref.watch(accountScopeProvider);
  final dirs = ref.watch(appDirsProvider);
  final gate = ref.watch(dbGateProvider);

  if (scope == null) {
    final memoryDb = AppDatabase.forTesting(NativeDatabase.memory());
    ref.onDispose(() => unawaited(memoryDb.close()));
    return memoryDb;
  }

  final database = AppDatabase.forAccountLazy(
    accountId: scope.accountId,
    dirs: dirs,
    gate: gate,
  );
  ref.onDispose(() {
    unawaited(_closeDbSafely(database, scope.accountId, dirs, gate));
  });
  return database;
});

Future<void> _closeDbSafely(
  AppDatabase database,
  String accountId,
  AppDirs dirs,
  DbGate gate,
) async {
  if (database.isClosed) return;
  try {
    final filePath = database.filePath ??
        (dirs.cachedNoBackupDir == null
            ? null
            : AccountPaths(
                accountId: accountId,
                noBackupRoot: dirs.cachedNoBackupDir!,
                cacheRoot: dirs.cachedCacheDir ?? dirs.cachedNoBackupDir!,
              ).dbFile.path);
    if (filePath != null) {
      await gate.run(filePath, database.close);
    } else {
      await database.close();
    }
  } catch (_) {
    try {
      await database.close();
    } catch (_) {}
  }
}

final chatDaoProvider = Provider<ChatDao>((ref) {
  final scope = ref.watch(accountScopeProvider);
  return ChatDao(ref.watch(appDatabaseProvider), scope: scope);
});

final apiClientProvider = Provider<ApiClient>((ref) {
  ref.watch(accountScopeProvider);
  final logger = ref.watch(appLoggerProvider);
  final api = ApiClient(
    ref.watch(tokenStoreProvider),
    deviceId: ref.watch(deviceIdProvider),
    logger: logger,
  );
  logger.attach(api);
  return api;
});

final mediaCacheProvider = Provider<AccountMediaCache?>((ref) {
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  final dirs = ref.watch(appDirsProvider);
  final cacheRoot = dirs.cachedCacheDir ??
      Directory(p.join(Directory.systemTemp.path, 'cpchat_app_dirs', 'cache'));
  final mediaDir = Directory(
    p.join(cacheRoot.path, 'accounts', scope.accountId, 'media'),
  );
  return AccountMediaCache(accountId: scope.accountId, mediaDir: mediaDir);
});

final mediaServiceProvider = Provider<MediaService>((ref) {
  final scope = ref.watch(accountScopeProvider);
  final dirs = ref.watch(appDirsProvider);
  return MediaService(
    ref.watch(apiClientProvider),
    logger: ref.watch(appLoggerProvider),
    uploadTempDir: scope == null
        ? null
        : () async => (await AccountPaths.resolve(scope.accountId, dirs)).uploadTmpDir,
  );
});

/// End-to-end encryption for direct chats, strictly scoped per account.
final e2eeManagerProvider = Provider<E2eeManager>((ref) {
  final scope = ref.watch(accountScopeProvider);
  final accountStore = ref.watch(accountStoreProvider);
  return E2eeManager(
    tokenStore: ref.watch(tokenStoreProvider),
    accountStore: accountStore,
    scope: scope,
    legacyMigration: ref.watch(legacyMigrationProvider),
    api: ref.watch(apiClientProvider),
    logger: ref.watch(appLoggerProvider),
  );
});

/// The stored access token, exposed for widgets that fetch private media.
final accessTokenProvider = FutureProvider<String?>((ref) async {
  ref.watch(accountScopeProvider);
  return ref.watch(tokenStoreProvider).readAccessToken();
});

final chatSocketProvider = Provider<ChatSocket>((ref) {
  final scope = ref.watch(accountScopeProvider);
  final dao = ref.watch(chatDaoProvider);
  final api = ref.watch(apiClientProvider);
  final tokenStore = ref.watch(tokenStoreProvider);
  final wiper = ref.watch(accountWiperProvider);

  final socket = ChatSocket(
    dao,
    api,
    tokenStore,
    scope: scope,
    logger: ref.watch(appLoggerProvider),
    serverRotatedAt: () => ref.read(e2eeManagerProvider).serverRotatedAt,
    beforeSync: scope == null
        ? null
        : () => wiper.flushPendingServerClears(
              accountId: scope.accountId,
              api: api,
              dao: dao,
            ),
    activeConversationId: () => ref.read(activeConversationIdProvider),
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
  // A hydrated / server-updated conversation refreshes any open ChatScreen's
  // cached metadata (members, header name, presence) without a manual refresh.
  final updateSubscription = socket.conversationUpdatedEvents.listen((id) {
    if (scope != null && !scope.isOpen) return;
    ref.invalidate(conversationMetadataProvider(id));
  });
  ref.onDispose(updateSubscription.cancel);
  // Live inbound messages raise a local notification; the sync/pagination paths
  // never call this, so catch-up never floods the tray.
  socket.onIncomingMessage = (message, {String? senderName}) {
    if (scope != null && !scope.isOpen) return;
    unawaited(
      ref.read(messageNotifierProvider).onLiveMessage(message, senderName: senderName),
    );
  };
  ref.onDispose(socket.dispose);
  return socket;
});

/// Registers this install for push delivery while a session is active.
final pushRegistrationProvider = Provider<PushRegistration>((ref) {
  ref.watch(accountScopeProvider);
  final registration = PushRegistration(
    ref.watch(apiClientProvider),
    logger: ref.watch(appLoggerProvider),
  );
  ref.onDispose(() => unawaited(registration.stop()));
  return registration;
});

/// The conversation currently on screen, set by `ChatScreen` while it is mounted.
class ActiveConversationNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(accountScopeProvider);
    return null;
  }

  void open(String conversationId) => state = conversationId;

  void close(String conversationId) {
    if (state == conversationId) state = null;
  }

  void reset() => state = null;
}

final activeConversationIdProvider =
    NotifierProvider<ActiveConversationNotifier, String?>(
  ActiveConversationNotifier.new,
);

/// Raises local notifications for live incoming messages, tagged with the
/// active account id so foreign-account taps can be dropped (§3.3).
final messageNotifierProvider = Provider<MessageNotifier>((ref) {
  final scope = ref.watch(accountScopeProvider);
  final dao = ref.watch(chatDaoProvider);
  return MessageNotifier(
    notifications: ref.watch(localNotificationServiceProvider),
    accountId: () => scope?.accountId,
    selfId: () => scope?.userId ?? ref.read(currentUserProvider)?.id,
    selfStatus: () => ref.read(currentUserProvider)?.status,
    appResumed: () => ref.read(appLifecycleProvider) == AppLifecycleState.resumed,
    activeConversationId: () => ref.read(activeConversationIdProvider),
    resolveNames: (conversationId) async {
      final row = await dao.conversation(conversationId);
      if (row == null) return null;
      if (row.type == 'group') {
        return (isGroup: true, displayName: row.name ?? 'Group');
      }
      return (
        isGroup: false,
        displayName: _directPeerLabel(row) ?? row.name ?? 'Chat',
      );
    },
  );
});

String? _directPeerLabel(LocalConversation conversation) =>
    formatDirectPeerLabel(conversation.peerName, conversation.peerNickname);

/// Owns the realtime session lifecycle: verifies partition integrity, boots
/// E2EE keys, connects the chat socket, starts push registration, and tears
/// everything down cleanly on logout (without wiping local history).
class SessionLifecycle {
  SessionLifecycle(this._ref);

  final Ref _ref;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _running = false;
  ChatSocket? _watchedSocket;
  VoidCallback? _socketConnectionListener;
  ChatSocket? _activeSocket;
  E2eeManager? _activeE2ee;
  PushRegistration? _activePush;
  AccountPaths? _activePaths;
  String? _lastBgE2eeMarker;
  Timer? _bgDisconnectTimer;
  bool _disconnectedForBackground = false;

  void onAppLifecycleChanged(AppLifecycleState state) {
    if (!_running) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _bgDisconnectTimer?.cancel();
      _bgDisconnectTimer = Timer(const Duration(seconds: 4), () {
        if (!_running) return;
        final current = _ref.read(appLifecycleProvider);
        if (current != AppLifecycleState.paused &&
            current != AppLifecycleState.detached) {
          return;
        }
        _disconnectedForBackground = true;
        unawaited(_activeSocket?.disconnect());
      });
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _bgDisconnectTimer?.cancel();
      _bgDisconnectTimer = null;
      unawaited(_handleResume());
    }
  }

  Future<void> _handleResume() async {
    if (!_running) return;
    final paths = _activePaths;
    final e2ee = _activeE2ee;
    if (paths != null && e2ee != null) {
      final currentMarker = await BackgroundPushHandler.readBackgroundE2eeMarker(
        paths.partitionDir,
      );
      if (currentMarker != null && currentMarker != _lastBgE2eeMarker) {
        _lastBgE2eeMarker = currentMarker;
        try {
          await PartitionLock.withLock(
            paths.partitionDir,
            () => e2ee.reloadSessionsFromDisk(),
            timeout: const Duration(seconds: 10),
          );
        } catch (error) {
          debugPrint('Reloading E2EE sessions on resume failed: $error');
        }
      }
      if (_ref.mounted) {
        unawaited(
          BackgroundPushHandler.drainDiagnostics(
            paths.partitionDir,
            _ref.read(appLoggerProvider),
          ),
        );
      }
    }
    if (_running && _disconnectedForBackground) {
      _disconnectedForBackground = false;
      unawaited(_activeSocket?.connect());
    }
  }

  void _attachSocketReconnectListener(ChatSocket socket) {
    if (identical(_watchedSocket, socket) && _socketConnectionListener != null) {
      return;
    }
    _detachSocketReconnectListener();
    void listener() {
      if (!_running) return;
      if (socket.connection.value.isConnected) {
        unawaited(_ref.read(pushRegistrationProvider).ensureRegistered());
      }
    }

    socket.connection.addListener(listener);
    _watchedSocket = socket;
    _socketConnectionListener = listener;
  }

  void _detachSocketReconnectListener() {
    final socket = _watchedSocket;
    final listener = _socketConnectionListener;
    if (socket != null && listener != null) {
      socket.connection.removeListener(listener);
    }
    _watchedSocket = null;
    _socketConnectionListener = null;
  }

  Future<void> start() async {
    final auth = _ref.read(authControllerProvider);
    if (!auth.isAuthenticated) return;
    // Ensure the account scope is synced even if auth was seeded without
    // overriding activeAccountUserIdProvider (e.g. cold-start widget tests).
    final userId = auth.session?.user.id;
    if (userId != null && _ref.read(activeAccountUserIdProvider) != userId) {
      _ref.read(activeAccountUserIdProvider.notifier).set(userId);
    }
    // Await any in-flight teardown before booting the next session (§Phase 3).
    final stopping = _stopping;
    if (stopping != null) {
      try {
        await stopping;
      } catch (_) {}
    }
    if (!_ref.read(authControllerProvider).isAuthenticated) return;
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
    final scope = _ref.read(accountScopeProvider);
    final db = _ref.read(appDatabaseProvider);
    final e2ee = _ref.read(e2eeManagerProvider);
    final socket = _ref.read(chatSocketProvider);
    final push = _ref.read(pushRegistrationProvider);
    final notifications = _ref.read(localNotificationServiceProvider);
    final logger = _ref.read(appLoggerProvider);
    _activeSocket = socket;
    _activeE2ee = e2ee;
    _activePush = push;

    var freshPartition = false;

    // 1 & 2. Verify partition integrity and bootstrap E2EE under the exclusive
    //        per-account `.partition.lock` so if a headless FCM background
    //        isolate was mid-decrypt as the user opened the app, we wait for
    //        it to finish committing SQLite + `e2ee_sessions` before loading.
    Future<void> verifyAndBootstrap(AccountPaths? paths) async {
      if (scope != null && db.isFileBacked && paths != null) {
        final accountStore = _ref.read(accountStoreProvider);
        if (accountStore != null) {
          try {
            final guard = PartitionGuard(
              store: accountStore,
              userId: scope.userId,
              paths: paths,
              gate: _ref.read(dbGateProvider),
              logger: logger,
            );
            final check = await guard.verify(db);
            freshPartition = check.isFreshStart;
          } catch (error) {
            debugPrint('PartitionGuard check failed: $error');
          }
        }
      }
      if (!_running || (scope != null && !scope.isOpen)) return;

      try {
        await e2ee.bootstrap();
      } catch (error) {
        debugPrint('E2EE bootstrap failed: $error');
      }
    }

    AccountPaths? resolvedPaths;
    if (scope != null && db.isFileBacked) {
      try {
        resolvedPaths = await AccountPaths.resolve(
          scope.accountId,
          _ref.read(appDirsProvider),
        );
      } catch (error) {
        debugPrint('AccountPaths.resolve failed: $error');
      }
    }
    _activePaths = resolvedPaths;

    if (resolvedPaths != null) {
      _lastBgE2eeMarker = await BackgroundPushHandler.readBackgroundE2eeMarker(
        resolvedPaths.partitionDir,
      );
      try {
        await PartitionLock.withLock(
          resolvedPaths.partitionDir,
          () => verifyAndBootstrap(resolvedPaths),
          timeout: const Duration(seconds: 10),
        );
      } catch (error) {
        logger.warn(
          'partition',
          'PartitionLock acquire during startup failed; skipping unlocked bootstrap',
          meta: {'error': error.toString()},
        );
        return;
      }
      unawaited(
        BackgroundPushHandler.drainDiagnostics(resolvedPaths.partitionDir, logger),
      );
    } else {
      await verifyAndBootstrap(null);
    }
    if (!_running || (scope != null && !scope.isOpen)) return;

    // 3. Connect socket (runs pending_server_clear flush + syncAll + outbox).
    _attachSocketReconnectListener(socket);
    await socket.connect();
    if (!_running || (scope != null && !scope.isOpen)) return;

    // 4. D1 fresh-partition group-history prompt.
    if (freshPartition && scope != null && _ref.mounted) {
      await _maybeShowFreshGroupPrompt();
    }

    // 5. If bootstrap (FcmService.initialize) is in flight, wait for it before
    //    starting push registration so FcmService.isAvailable is already true.
    final pendingBootstrap = _ref.read(bootstrapTrackerProvider).inFlight;
    if (pendingBootstrap != null) {
      try {
        await pendingBootstrap.timeout(const Duration(seconds: 10));
      } catch (_) {}
      if (!_running || (scope != null && !scope.isOpen)) return;
    }

    try {
      await push.start();
    } catch (error) {
      logger.warn(
        'fcm',
        'Push registration start failed',
        meta: {'error': error.toString()},
      );
    }

    try {
      await notifications.requestPermission();
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }

  Future<void> _maybeShowFreshGroupPrompt() async {
    try {
      final dao = _ref.read(chatDaoProvider);
      final convs = await dao.conversations();
      final hasGroupHistory = convs.any(
        (c) => c.type == 'group' && c.lastSeq > c.clearedSeq,
      );
      if (hasGroupHistory) {
        _ref.read(freshPartitionPromptProvider.notifier).show();
      }
    } catch (_) {
      // Best effort.
    }
  }

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
    _bgDisconnectTimer?.cancel();
    _bgDisconnectTimer = null;
    _disconnectedForBackground = false;
    _activePaths = null;
    _lastBgE2eeMarker = null;
    _detachSocketReconnectListener();
    final starting = _starting;
    if (starting != null) {
      try {
        await starting.timeout(const Duration(seconds: 2));
      } catch (error) {
        debugPrint('Session stop awaiting boot failed: $error');
      }
    }
    final socket = _activeSocket ?? (_ref.mounted ? _ref.read(chatSocketProvider) : null);
    final e2ee = _activeE2ee ?? (_ref.mounted ? _ref.read(e2eeManagerProvider) : null);
    final push = _activePush ?? (_ref.mounted ? _ref.read(pushRegistrationProvider) : null);
    _activeSocket = null;
    _activeE2ee = null;
    _activePush = null;

    if (socket != null) {
      try {
        await socket.disconnect();
      } catch (error) {
        debugPrint('Session teardown socket disconnect failed: $error');
      }
    }
    if (e2ee != null) {
      try {
        await e2ee.flush();
      } catch (error) {
        debugPrint('Session teardown E2EE flush failed: $error');
      }
    }
    if (push != null) {
      try {
        await push.stop();
      } catch (error) {
        debugPrint('Session teardown push stop failed: $error');
      }
    }
    e2ee?.reset();
  }
}

final sessionLifecycleProvider = Provider<SessionLifecycle>(SessionLifecycle.new);

class SessionRuntime extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      final lifecycle = ref.read(sessionLifecycleProvider);
      if (next.isAuthenticated) {
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

/// Resolves storage roots, resumes interrupted L2 wipes, migrates legacy
/// single-DB installs, resolves the device id, and initializes notifications.
final bootstrapProvider = FutureProvider<void>((ref) async {
  final tracker = ref.read(bootstrapTrackerProvider);
  final completer = Completer<void>();
  tracker.inFlight = completer.future;
  try {
    final dirs = ref.watch(appDirsProvider);
    await dirs.initialize();

    final tokenStore = ref.watch(tokenStoreProvider);
    final resolvedNoBackup = dirs.cachedNoBackupDir?.path;
    if (resolvedNoBackup != null && resolvedNoBackup.isNotEmpty) {
      await tokenStore.writeResolvedNoBackupRoot(resolvedNoBackup);
    }

    // Finish any crash-interrupted L2 partition deletions before opening DBs.
    try {
      await ref.read(accountWiperProvider).resumePendingWipes();
    } catch (error) {
      debugPrint('Pending wipe janitor failed: $error');
    }

    // Upgrade pre-partition installs safely and idempotently (§3.1).
    try {
      await ref.read(legacyMigrationProvider).runIfNeeded();
    } catch (error) {
      debugPrint('Legacy migration failed: $error');
    }

    var deviceId = ref.read(deviceIdProvider) ?? await tokenStore.readDeviceId();
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await tokenStore.writeDeviceId(deviceId);
    }
    ref.read(deviceIdProvider.notifier).set(deviceId);

    await FcmService.initialize(logger: ref.read(appLoggerProvider));
    await CrashReporter.initialize();
    await ref.read(localNotificationServiceProvider).initialize();
  } finally {
    if (!completer.isCompleted) completer.complete();
  }
});

/// Reads the persisted session from local storage without any network access.
Future<AuthState> hydrateAuthState(TokenStore tokenStore) async {
  final access = await tokenStore.readAccessToken();
  final refresh = await tokenStore.readRefreshToken();
  if (access == null && refresh == null) return const AuthState.unauthenticated();

  final userId = await tokenStore.readUserId();
  if (userId == null) return const AuthState.unauthenticated();

  final user = await tokenStore.readUser();
  return AuthState.authenticated(
    AuthSession(
      user: user ?? User(id: userId, name: ''),
      accessToken: access ?? '',
      refreshToken: refresh ?? '',
      expiresIn: 0,
    ),
  );
}

class AuthController extends Notifier<AuthState> {
  // ignore: prefer_initializing_formals
  AuthController({AuthState? initial}) : _initial = initial;

  final AuthState? _initial;

  @override
  AuthState build() => _initial ?? const AuthState.initializing();

  @override
  set state(AuthState value) {
    super.state = value;
    ref.read(activeAccountUserIdProvider.notifier).set(value.session?.user.id);
  }

  Future<void> login({required String identifier, required String password}) async {
    final session = await ref.read(apiClientProvider).login(
          identifier: identifier,
          password: password,
        );
    await _activateAccount(session.user);
    state = AuthState.authenticated(session);
  }

  Future<void> register({
    required String phoneOrEmail,
    required String username,
    required String name,
    required String password,
  }) async {
    final session = await ref.read(apiClientProvider).register(
          phoneOrEmail: phoneOrEmail,
          username: username,
          name: name,
          password: password,
        );
    await _activateAccount(session.user);
    state = AuthState.authenticated(session);
  }

  Future<void> _activateAccount(User user) async {
    final accountId = accountIdForUser(user.id);
    final tokenStore = ref.read(tokenStoreProvider);
    await tokenStore.saveUser(user);
    await tokenStore.writeActiveAccountId(accountId);
    await ref.read(accountRegistryProvider).register(
          user.id,
          displayName: user.name,
          username: user.username,
        );
    try {
      await ref.read(localNotificationServiceProvider).cancelForeignAccounts(accountId);
    } catch (_) {}
  }

  Future<void> restore() async {
    try {
      final restored = await hydrateAuthState(ref.read(tokenStoreProvider));
      final user = restored.session?.user;
      if (user != null) {
        final accountId = accountIdForUser(user.id);
        await ref.read(tokenStoreProvider).writeActiveAccountId(accountId);
        await ref.read(accountRegistryProvider).register(
              user.id,
              displayName: user.name.isEmpty ? null : user.name,
              username: user.username,
            );
      }
      state = restored;
    } catch (error) {
      debugPrint('Session restore failed: $error');
      state = const AuthState.unauthenticated();
    }
  }

  Future<void> validateSession() async {
    final current = state.session;
    if (current == null) return;
    try {
      final user = await ref.read(apiClientProvider).me();
      if (!state.isAuthenticated) return;
      await ref.read(tokenStoreProvider).saveUser(user);
      await ref.read(accountRegistryProvider).register(
            user.id,
            displayName: user.name,
            username: user.username,
          );
      state = AuthState.authenticated(
        AuthSession(
          user: user,
          accessToken: current.accessToken,
          refreshToken: current.refreshToken,
          expiresIn: current.expiresIn,
        ),
      );
    } on ApiException catch (error) {
      if (error.isAuthFailure || error.statusCode == 403) {
        await logout();
      }
    } catch (error) {
      debugPrint('Session validation skipped: $error');
    }
  }

  /// Upper bound on each network teardown step (§2.3: <= 3s, configurable in tests).
  Duration logoutStepTimeout = const Duration(seconds: 3);

  /// Strict 9-step teardown (§2.3).
  ///
  /// Standard logout (`wipeDeviceData: false`) preserves the account's isolated
  /// SQLite partition and `acct.<id>.e2ee_*` keys for R2 same-user re-login.
  /// Passing `wipeDeviceData: true` runs L2 ("remove my data from this device"):
  /// clears server history (best-effort / queued if offline) and deletes the
  /// entire local partition, keys, media cache, and registry entry.
  Future<void> logout({bool wipeDeviceData = false}) async {
    final scope = ref.read(accountScopeProvider);
    final accountId = scope?.accountId;
    final api = ref.read(apiClientProvider);
    final db = ref.read(appDatabaseProvider);
    final e2ee = ref.read(e2eeManagerProvider);
    final push = ref.read(pushRegistrationProvider);
    final notifications = ref.read(localNotificationServiceProvider);
    final messageNotifier = ref.read(messageNotifierProvider);
    final mediaCache = ref.read(mediaCacheProvider);
    final wiper = ref.read(accountWiperProvider);
    final dirs = ref.read(appDirsProvider);
    final dbGate = ref.read(dbGateProvider);
    final registry = ref.read(accountRegistryProvider);
    final tokenStore = ref.read(tokenStoreProvider);

    try {
      // 0. Invalidate current account epoch so stale async continuations fail closed.
      scope?.beginClose();

      // 1. Push unregister (needs auth token still present; best-effort).
      try {
        await push.unregister(timeout: logoutStepTimeout).timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout push unregister failed: $error');
      }

      // 2. Clear notifications for this account and reset dedupe buffer.
      try {
        if (accountId != null) {
          await notifications.cancelForAccount(accountId).timeout(logoutStepTimeout);
        } else {
          await notifications.cancelAll().timeout(logoutStepTimeout);
        }
      } catch (error) {
        debugPrint('Logout notification clear failed: $error');
      }
      messageNotifier.reset();
      ref.read(activeConversationIdProvider.notifier).reset();

      // 3. Stop realtime session (disconnect socket, await sync barrier, flush E2EE).
      try {
        await ref.read(sessionLifecycleProvider).stop().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout teardown failed: $error');
      }

      // 4. Flush any remaining pending ratchet-session writes (R-2).
      try {
        await e2ee.flush().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout E2EE flush failed: $error');
      }

      // 5a. If L2 wipe requested, clear server history while auth is still valid.
      if (wipeDeviceData && accountId != null) {
        try {
          await api.clearAllHistory().timeout(logoutStepTimeout);
          await registry.setPendingL2ServerClear(accountId, false);
        } catch (error) {
          debugPrint('Logout L2 server clear offline, flagging for next login: $error');
          await registry.setPendingL2ServerClear(accountId, true);
        }
      }

      // 5b. Revoke refresh token on the server (best-effort).
      try {
        await api.logout().timeout(logoutStepTimeout);
      } catch (error) {
        debugPrint('Logout API call failed: $error');
      }

      // 6. Close account DB via DbGate, clear memory image cache and upload tmp.
      //    If L2 wipe requested, delete the entire partition + keys + registry.
      if (wipeDeviceData && accountId != null) {
        try {
          await wiper.wipeAccountPartition(
            accountId: accountId,
            openDb: db,
            mediaCache: mediaCache,
            notifyServer: false, // already attempted in step 5a
          );
        } catch (error) {
          debugPrint('Logout L2 partition wipe failed: $error');
        }
      } else {
        if (accountId != null) {
          try {
            await _closeDbSafely(db, accountId, dirs, dbGate)
                .timeout(logoutStepTimeout);
          } catch (error) {
            debugPrint('Logout DB close failed: $error');
          }
          try {
            if (dirs.cachedCacheDir != null) {
              final paths = AccountPaths(
                accountId: accountId,
                noBackupRoot: dirs.cachedNoBackupDir ?? dirs.cachedCacheDir!,
                cacheRoot: dirs.cachedCacheDir!,
              );
              await paths.clearUploadTmp();
            }
          } catch (_) {}
        }
        evictMemoryImageCache();
      }
    } finally {
      // 7. Clear session pointers ONLY (preserves device_id, registry, and
      //    non-wiped account DB + acct.<id>.e2ee_*).
      try {
        await tokenStore.clear();
      } catch (error) {
        debugPrint('Logout token clear failed: $error');
      }
      ref.read(appLoggerProvider).clear();
      // 8. Flip auth state -> disposes every provider watching accountScopeProvider.
      state = const AuthState.unauthenticated();
    }
  }

  void applyUser(User user) {
    final current = state.session;
    if (current == null) return;
    state = AuthState.authenticated(
      AuthSession(
        user: user,
        accessToken: current.accessToken,
        refreshToken: current.refreshToken,
        expiresIn: current.expiresIn,
      ),
    );
    unawaited(ref.read(tokenStoreProvider).saveUser(user));
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authControllerProvider).session?.user;
});

/// The chat list, backed by the account's local mirror.
final conversationsProvider = StreamProvider<List<LocalConversation>>((ref) {
  ref.watch(accountScopeProvider);
  return ref.watch(chatDaoProvider).watchConversations();
});

/// Messages for one conversation, backed by the account's local mirror.
final messagesProvider =
    StreamProvider.family<List<LocalMessage>, String>((ref, conversationId) {
  ref.watch(accountScopeProvider);
  return ref.watch(chatDaoProvider).watchMessages(conversationId);
});
