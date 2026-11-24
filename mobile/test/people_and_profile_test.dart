import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:cp_chat/core/database/app_database.dart';
import 'package:cp_chat/core/database/chat_dao.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/network/api_client.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/people/people_screen.dart';
import 'package:cp_chat/features/profile/my_profile_screen.dart';
import 'package:cp_chat/features/profile/user_profile_screen.dart';

import 'support/factories.dart';

/// Answers directory, presence and conversation calls without a network.
class _FakeApi extends ApiClient {
  _FakeApi({required this.friendsList, required this.profile})
      : super(TokenStore());

  final List<User> friendsList;
  final User profile;

  final List<String> searchedQueries = [];
  int directChats = 0;
  int addFriends = 0;

  @override
  Future<List<User>> friends() async => friendsList;

  @override
  Future<List<User>> searchUsers(String query, {int limit = 20}) async {
    searchedQueries.add(query);
    final needle = query.toLowerCase();
    return [
      for (final user in friendsList)
        if (user.name.toLowerCase().contains(needle) ||
            (user.phoneOrEmail ?? '').toLowerCase().contains(needle))
          user,
    ];
  }

  @override
  Future<User> user(String id) async => profile;

  @override
  Future<Presence> presence(String userId) async =>
      Presence(userId: userId, online: false);

  @override
  Future<Conversation> createDirectConversation(String otherUserId) async {
    directChats += 1;
    return conversation(
      'conv-direct',
      selfId: 'me',
      peerId: otherUserId,
      peerName: profile.name,
    );
  }

  @override
  Future<User> addFriend({String? userId, String? identifier}) async {
    addFriends += 1;
    return profile.copyWith(isFriend: true);
  }

  @override
  Future<void> removeFriend(String friendId) async {}
}

/// Token store backed by memory so sign-out can wipe it without the platform
/// keychain.
class _MemoryTokenStore extends TokenStore {
  _MemoryTokenStore({this.access, this.refresh, this.userId});

  String? access;
  String? refresh;
  String? userId;

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<String?> readUserId() async => userId;

  @override
  Future<void> clear() async {
    access = null;
    refresh = null;
    userId = null;
  }
}

/// Serves the caller's profile and mirrors the logout contract by clearing the
/// token store, without touching the network.
class _ProfileApi extends ApiClient {
  _ProfileApi(this._profile, this._store) : super(_store);

  final User _profile;
  final _MemoryTokenStore _store;
  int logouts = 0;

  @override
  Future<User> me() async => _profile;

  @override
  Future<void> logout() async {
    logouts += 1;
    await _store.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  GoRouter routerFor() => GoRouter(
        initialLocation: '/people',
        routes: [
          GoRoute(
            path: '/people',
            builder: (context, state) => const PeopleScreen(),
          ),
          GoRoute(
            path: '/users/:id',
            builder: (context, state) => UserProfileScreen(
              userId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/conversations/:id',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Text('opened ${state.pathParameters['id']}'),
              ),
            ),
          ),
        ],
      );

  Future<void> pumpApp(WidgetTester tester, _FakeApi api) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          appDatabaseProvider.overrideWithValue(database),
          currentUserProvider.overrideWithValue(const User(id: 'me', name: 'Me')),
        ],
        child: MaterialApp.router(routerConfig: routerFor()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders "Name (nickname)" and plain "Name"', (tester) async {
    final api = _FakeApi(
      friendsList: [
        user('u1', name: 'Alice', nickname: 'Ali', effectiveStatus: 'online'),
        user('u2', name: 'Bob', effectiveStatus: 'offline'),
      ],
      profile: user('u1', name: 'Alice', nickname: 'Ali'),
    );

    await pumpApp(tester, api);

    expect(find.text('Alice (Ali)'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('searching by name or email calls the directory', (tester) async {
    final api = _FakeApi(
      friendsList: [
        user('u1', name: 'Alice', nickname: 'Ali', effectiveStatus: 'online'),
        user('u2', name: 'Bob', effectiveStatus: 'offline'),
      ],
      profile: user('u1', name: 'Alice', nickname: 'Ali'),
    );

    await pumpApp(tester, api);

    await tester.enterText(find.byType(TextField), 'bob');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(api.searchedQueries, contains('bob'));
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Alice (Ali)'), findsNothing);
  });

  testWidgets('a profile Message button opens the direct conversation',
      (tester) async {
    final alice = user('u1', name: 'Alice', nickname: 'Ali');
    final api = _FakeApi(friendsList: [alice], profile: alice);

    await pumpApp(tester, api);

    await tester.tap(find.text('Alice (Ali)'));
    await tester.pumpAndSettle();

    expect(find.byType(UserProfileScreen), findsOneWidget);
    expect(find.text('Alice (Ali)'), findsOneWidget);

    await tester.tap(find.text('Message'));
    await tester.pumpAndSettle();

    expect(api.directChats, 1);
    expect(find.text('opened conv-direct'), findsOneWidget);
  });

  testWidgets('adding a friend by identifier closes the dialog cleanly',
      (tester) async {
    final alice = user('u1', name: 'Alice', nickname: 'Ali');
    final api = _FakeApi(friendsList: [alice], profile: alice);

    await pumpApp(tester, api);

    await tester.tap(find.byTooltip('Add friend'));
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'alice@example.com');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(api.addFriends, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding a friend from their profile closes cleanly',
      (tester) async {
    final alice = user('u1', name: 'Alice', nickname: 'Ali');
    final api = _FakeApi(friendsList: [alice], profile: alice);

    await pumpApp(tester, api);

    await tester.tap(find.text('Alice (Ali)'));
    await tester.pumpAndSettle();
    // The Stitch contact profile uses an icon-only friend action.
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();

    expect(api.addFriends, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign-out clears tokens, local data, and returns to /auth',
      (tester) async {
    final store = _MemoryTokenStore(access: 'a', refresh: 'r', userId: 'me');
    final api = _ProfileApi(user('me', name: 'Me'), store);
    final dao = ChatDao(database);
    await dao.upsertConversations([conversation('conv-1', selfId: 'me')]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          appDatabaseProvider.overrideWithValue(database),
          tokenStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/profile',
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const MyProfileScreen(),
              ),
              GoRoute(
                path: '/auth',
                builder: (context, state) =>
                    const Scaffold(body: Text('auth-screen')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('Sign out'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(api.logouts, 1);
    expect(store.access, isNull);
    expect(store.refresh, isNull);
    expect(await dao.conversations(), isEmpty);
    expect(find.text('auth-screen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
