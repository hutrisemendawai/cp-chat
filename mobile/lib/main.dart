import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/notifications/crash_reporter.dart';
import 'core/notifications/fcm_service.dart';
import 'core/models/models.dart';
import 'core/providers.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registered before runApp so a push that arrives while the app is backgrounded
  // or swiped away is handled by the headless isolate, not silently dropped.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  // Install the crash handlers before the first frame so an early error is not
  // lost. This is a no-op in debug builds.
  await CrashReporter.initialize();
  runApp(const ProviderScope(child: CpChatApp()));
}

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/conversations',
    routes: [
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: '/users/:id',
        builder: (context, state) => UserProfileScreen(
          userId: state.pathParameters['id']!,
        ),
      ),
      // Detail routes live on the root navigator so they cover the bottom bar.
      GoRoute(
        path: '/conversations/new-group',
        builder: (context, state) => const CreateGroupScreen(),
      ),
      GoRoute(
        path: '/conversations/:id',
        builder: (context, state) => ChatScreen(
          conversationId: state.pathParameters['id']!,
        ),
        routes: [
          GoRoute(
            path: 'info',
            builder: (context, state) => GroupInfoScreen(
              conversationId: state.pathParameters['id']!,
            ),
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/conversations',
                builder: (context, state) => const ConversationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/people',
                builder: (context, state) => const PeopleScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const MyProfileScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
    redirect: (context, state) {
      final session = ref.read(authControllerProvider);
      final atAuth = state.matchedLocation == '/auth';
      if (session == null && !atAuth) return '/auth';
      if (session != null && atAuth) return '/conversations';
      return null;
    },
    refreshListenable: _AuthRefresh(ref),
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Bridges Riverpod auth state into GoRouter's redirect mechanism.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(this._ref) {
    _subscription = _ref.listen<AuthSession?>(
      authControllerProvider,
      (previous, next) {
        // A signed-out session must not leave the previous account's directory
        // results and presence cached for the next user on this device.
        if (next == null && previous != null) {
          _ref.invalidate(peopleControllerProvider);
          _ref.invalidate(presenceProvider);
          _ref.invalidate(friendsProvider);
        }
        notifyListeners();
      },
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AuthSession?> _subscription;

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
  StreamSubscription<String>? _localTapSubscription;
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
    await ref.read(bootstrapProvider.future);

    // Keep the session runtime subscribed for the whole app lifetime so a
    // manual login (not just a cold-start restore) starts the socket. The
    // provider's own listener reacts to every auth transition; this read also
    // constructs it before the first transition can occur.
    ref.read(sessionRuntimeProvider);

    // Restore a persisted session before the router's first redirect settles.
    await ref.read(authControllerProvider.notifier).restore();

    // A restored session is applied by assigning state, which the runtime
    // listener picks up; call start() explicitly so the first boot does not
    // depend on listener ordering.
    if (ref.read(authControllerProvider) != null) {
      await ref.read(sessionRuntimeProvider.notifier).start();
    }

    // Local notifications are independent of Firebase, so they are always
    // wired; FCM streams are only touched when Firebase actually initialized.
    final notifications = ref.read(localNotificationServiceProvider);
    _localTapSubscription ??= notifications.onNotificationTap.listen(_openConversation);
    if (FcmService.isAvailable) {
      _fcmTapSubscription ??= FcmService.onNotificationTap.listen(_openFromMessage);
      _foregroundSubscription ??=
          FcmService.onForegroundMessage.listen(_onForegroundMessage);
    }

    // A notification that launched the app from terminated routes straight in.
    final coldStart = notifications.coldStartConversationId;
    if (coldStart != null) _openConversation(coldStart);
    await _routeFromInitialNotification();
  }

  Future<void> _routeFromInitialNotification() async {
    if (!FcmService.isAvailable) return;
    final initial = await FcmService.initialMessage();
    if (initial != null) _openFromMessage(initial);
  }

  /// A foreground FCM push is only surfaced when the local rules allow it; a
  /// message that also arrives over the socket is deduplicated by id.
  void _onForegroundMessage(RemoteMessage message) {
    final content = notificationContentFromFcm(message);
    if (content == null) return;
    unawaited(
      ref.read(messageNotifierProvider).onForegroundFcm(
        conversationId: content.conversationId,
        messageId: content.messageId ?? content.conversationId,
        title: content.title,
        body: content.body,
      ),
    );
  }

  void _openConversation(String conversationId) {
    if (conversationId.isEmpty) return;
    ref.read(routerProvider).push('/conversations/$conversationId');
  }

  void _openFromMessage(RemoteMessage message) {
    final content = notificationContentFromFcm(message);
    if (content == null) return;
    _openConversation(content.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'CP Chat',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
    );
  }
}
