import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/profile/user_profile_screen.dart';
import 'package:cp_chat/main.dart';

import 'support/factories.dart' as factories;

class _FakeAuth extends AuthController {
  @override
  AuthState build() => const AuthState.authenticated(
        AuthSession(
          user: User(id: 'me', name: 'Me'),
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresIn: 900,
        ),
      );
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(TokenStore());

  @override
  Future<User> me() async => const User(id: 'me', name: 'Me');

  @override
  Future<User> user(String id) async => factories.user(id, name: 'Them');

  @override
  Future<List<User>> friends() async => const [];

  @override
  Future<List<Conversation>> conversations({int limit = 50}) async => [];

  @override
  Future<Conversation> conversation(String id) async =>
      factories.conversation('conv-1', selfId: 'me', peerId: 'them', peerName: 'Them');

  @override
  Future<MessagePage> messages(
    String conversationId, {
    int? beforeSeq,
    int limit = 50,
  }) async =>
      const MessagePage(messages: [], hasMore: false);

  @override
  Future<SyncResult> sync(
    String conversationId, {
    required int afterSeq,
    int limit = 200,
  }) async =>
      const SyncResult(messages: [], latestSeq: 0);

  @override
  Future<Presence> presence(String userId) async =>
      Presence(userId: userId, online: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late ProviderContainer container;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(_FakeAuth.new),
        apiClientProvider.overrideWithValue(_FakeApi()),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  testWidgets('tabs switch and detail routes cover the bottom bar', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            final router = ref.watch(routerProvider);
            return MaterialApp.router(routerConfig: router);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);

    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(find.text('Search by username or email...'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('My Profile'), findsOneWidget);

    final router = container.read(routerProvider);

    router.go('/conversations/new-group');
    await tester.pumpAndSettle();
    expect(find.text('New group'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    router.go('/users/them');
    await tester.pumpAndSettle();
    expect(find.byType(UserProfileScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    router.go('/conversations/conv-1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
