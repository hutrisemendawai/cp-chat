import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/models/models.dart';
import 'core/notifications/crash_reporter.dart';
import 'core/notifications/fcm_service.dart';
import 'core/notifications/local_notification_service.dart';
import 'core/providers.dart';
import 'core/storage/token_store.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/conversations/conversations_screen.dart';
import 'features/groups/create_group_screen.dart';
import 'features/groups/group_info_screen.dart';
import 'features/home/home_shell.dart';
import 'features/people/people_controller.dart';
import 'features/people/people_screen.dart';
import 'features/presence/presence_controller.dart';
import 'features/profile/my_profile_screen.dart';
import 'features/profile/user_profile_screen.dart';
import 'features/search/search_screen.dart';
import 'features/splash/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registered before runApp so a push that arrives while the app is backgrounded
  // or swiped away is handled by the headless isolate, not silently dropped.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // Install the crash handlers before the first frame so an early error is not
  // lost. This is a no-op in debug builds.
  await CrashReporter.initialize();

  // Hydrate the persisted session from local storage before the first frame.
  final tokenStore = TokenStore();
  AuthState initialAuth;
  try {
    initialAuth = await hydrateAuthState(tokenStore);
  } catch (error) {
    debugPrint('Initial session hydration failed: $error');
    initialAuth = const AuthState.initializing();
  }

  runApp(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokenStore),
        activeAccountUserIdProvider.overrideWith(
          () => ActiveAccountUserIdNotifier(initial: initialAuth.session?.user.id),
        ),
        authControllerProvider.overrideWith(() => AuthController(initial: initialAuth)),
      ],
      child: const CpChatApp(),
    ),
  );
}

final routerProvider = Provider<GoRouter>((ref) {
  ValueKey<String> accountKey(String route) {
    final accountId = ref.read(accountScopeProvider)?.accountId ?? 'signed-out';
    return ValueKey<String>('$accountId:$route');
  }

  final router = GoRouter(
    initialLocation: '/conversations',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => SearchScreen(key: accountKey('search')),
      ),
      GoRoute(
        path: '/users/:id',
        builder: (context, state) => UserProfileScreen(
          key: accountKey('user:${state.pathParameters['id']}'),
          userId: state.pathParameters['id']!,
        ),
      ),
      // Detail routes live on the root navigator so they cover the bottom bar.
      GoRoute(
        path: '/conversations/new-group',
        builder: (context, state) => CreateGroupScreen(
          key: accountKey('new-group'),
        ),
      ),
      GoRoute(
        path: '/conversations/:id',
        builder: (context, state) => ChatScreen(
          key: accountKey('chat:${state.pathParameters['id']}'),
          conversationId: state.pathParameters['id']!,
        ),
        routes: [
          GoRoute(
            path: 'info',
            builder: (context, state) => GroupInfoScreen(
              key: accountKey('info:${state.pathParameters['id']}'),
              conversationId: state.pathParameters['id']!,
            ),
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => KeyedSubtree(
          key: accountKey('shell'),
          child: HomeShell(navigationShell: navigationShell),
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/conversations',
                builder: (context, state) => ConversationsScreen(
                  key: accountKey('conversations'),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/people',
                builder: (context, state) => PeopleScreen(
                  key: accountKey('people'),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => MyProfileScreen(
                  key: accountKey('profile'),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final atAuth = state.matchedLocation == '/auth';
      final atSplash = state.matchedLocation == '/splash';

      if (auth.isInitializing) return atSplash ? null : '/splash';

      if (auth.isAuthenticated) {
        return (atAuth || atSplash) ? '/conversations' : null;
      }

      return atAuth ? null : '/auth';
    },
    refreshListenable: _AuthRefresh(ref),
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Bridges Riverpod auth state into GoRouter's redirect mechanism.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(this._ref) {
    _subscription = _ref.listen<AuthState>(
      authControllerProvider,
      (previous, next) {
        // Belt-and-suspenders invalidation alongside accountScopeProvider.
        if ((previous?.isAuthenticated ?? false) && !next.isAuthenticated) {
          _ref.invalidate(peopleControllerProvider);
          _ref.invalidate(presenceProvider);
          _ref.invalidate(friendsProvider);
        }
        notifyListeners();
      },
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

class CpChatApp extends ConsumerStatefulWidget {
  const CpChatApp({super.key});

  @override
  ConsumerState<CpChatApp> createState() => _CpChatAppState();
}

class _CpChatAppState extends ConsumerState<CpChatApp> with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _fcmTapSubscription;
  StreamSubscription<NotificationTapTarget>? _localTapSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fcmTapSubscription?.cancel();
    _localTapSubscription?.cancel();
    _foregroundSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLifecycleProvider.notifier).set(state);
  }

  Future<void> _bootstrap() async {
    if (ref.read(authControllerProvider).isInitializing) {
      await ref.read(authControllerProvider.notifier).restore();
    }

    ref.read(sessionRuntimeProvider);

    try {
      await ref.read(bootstrapProvider.future);
    } catch (error) {
      debugPrint('Bootstrap failed: $error');
    }

    if (ref.read(authControllerProvider).isAuthenticated) {
      unawaited(ref.read(sessionRuntimeProvider.notifier).start());
      unawaited(ref.read(authControllerProvider.notifier).validateSession());
    }

    final notifications = ref.read(localNotificationServiceProvider);
    _localTapSubscription ??=
        notifications.onNotificationTapTarget.listen(_openFromLocalTarget);
    if (FcmService.isAvailable) {
      _fcmTapSubscription ??= FcmService.onNotificationTap.listen(_openFromMessage);
      _foregroundSubscription ??=
          FcmService.onForegroundMessage.listen(_onForegroundMessage);
    }

    // Account-checked cold-start routing (§3.3): drop foreign or signed-out taps.
    final coldStart = notifications.coldStartTarget;
    if (coldStart != null) {
      notifications.clearColdStart();
      _openFromLocalTarget(coldStart);
    }
    await _routeFromInitialNotification();
  }

  Future<void> _routeFromInitialNotification() async {
    if (!FcmService.isAvailable) return;
    final initial = await FcmService.initialMessage();
    if (initial != null) _openFromMessage(initial);
  }

  /// Drops foreground FCM pushes targeting a different or signed-out account (§3.3).
  void _onForegroundMessage(RemoteMessage message) {
    final content = notificationContentFromFcm(message);
    if (content == null) return;
    final scope = ref.read(accountScopeProvider);
    if (!shouldHandleFcmForAccount(
      recipientUserId: content.recipientUserId,
      activeAccountId: scope?.accountId,
      hasSession: ref.read(authControllerProvider).isAuthenticated,
    )) {
      return;
    }
    unawaited(
      ref.read(messageNotifierProvider).onForegroundFcm(
            conversationId: content.conversationId,
            messageId: content.messageId ?? content.conversationId,
            title: content.title,
            body: content.body,
          ),
    );
  }

  void _openFromLocalTarget(NotificationTapTarget target) {
    final activeAccountId = ref.read(accountScopeProvider)?.accountId;
    if (!ref.read(authControllerProvider).isAuthenticated ||
        !target.matchesActiveAccount(activeAccountId)) {
      return;
    }
    _openConversation(target.conversationId);
  }

  void _openConversation(String conversationId) {
    if (conversationId.isEmpty) return;
    if (!ref.read(authControllerProvider).isAuthenticated) return;
    ref.read(routerProvider).push('/conversations/$conversationId');
  }

  void _openFromMessage(RemoteMessage message) {
    final content = notificationContentFromFcm(message);
    if (content == null) return;
    final scope = ref.read(accountScopeProvider);
    if (!shouldHandleFcmForAccount(
      recipientUserId: content.recipientUserId,
      activeAccountId: scope?.accountId,
      hasSession: ref.read(authControllerProvider).isAuthenticated,
    )) {
      return;
    }
    _openConversation(content.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final accountId = ref.watch(accountScopeProvider)?.accountId ?? 'signed-out';

    return KeyedSubtree(
      key: ValueKey<String>('app:$accountId'),
      child: MaterialApp.router(
        title: 'CP Chat',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
      ),
    );
  }
}
