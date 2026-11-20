import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/notifications/fcm_service.dart';
import 'core/models/models.dart';
import 'core/providers.dart';
import 'features/auth/auth_screen.dart';
import 'features/chat/chat_controller.dart';
import 'features/chat/chat_screen.dart';
import 'features/conversations/conversations_screen.dart';
import 'features/groups/create_group_screen.dart';
import 'features/groups/group_info_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        path: '/conversations',
        builder: (context, state) => const ConversationsScreen(),
        routes: [
          GoRoute(
            path: 'new-group',
            builder: (context, state) => const CreateGroupScreen(),
          ),
          GoRoute(
            path: ':id',
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
      (_, _) => notifyListeners(),
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

class _CpChatAppState extends ConsumerState<CpChatApp> {
  StreamSubscription<dynamic>? _tapSubscription;
  PushRegistration? _push;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _tapSubscription?.cancel();
    unawaited(_push?.stop());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await ref.read(bootstrapProvider.future);

    // Restore a persisted session before the router's first redirect settles.
    await ref.read(authControllerProvider.notifier).restore();

    if (ref.read(authControllerProvider) != null) {
      await _startSessionRuntime();
    }

    ref.listen<AuthSession?>(authControllerProvider, (previous, next) {
      if (previous == null && next != null) {
        unawaited(_startSessionRuntime());
      }
    });
  }

  Future<void> _startSessionRuntime() async {
    final socket = ref.read(chatSocketProvider);
    await socket.connect();

    _push ??= PushRegistration(ref.read(apiClientProvider));
    await _push!.start();

    await _routeFromInitialNotification();
    _tapSubscription ??= FcmService.onNotificationTap.listen(_openFromMessage);
  }

  Future<void> _routeFromInitialNotification() async {
    final initial = await FcmService.initialMessage();
    if (initial != null) _openFromMessage(initial);
  }

  void _openFromMessage(dynamic message) {
    try {
      final conversationId = message.data['conversation_id'] as String?;
      if (conversationId == null) return;
      ref.read(routerProvider).push('/conversations/$conversationId');
    } catch (_) {
      // Malformed payloads are ignored; the chat list still works.
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'CP Chat',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
    );
  }
}
