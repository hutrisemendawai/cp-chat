import 'dart:io';

import 'package:cp_chat/core/models/call_models.dart';
import 'package:cp_chat/core/models/models.dart';
import 'package:cp_chat/core/providers.dart';
import 'package:cp_chat/core/storage/app_dirs.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:cp_chat/features/calls/call_controller.dart';
import 'package:cp_chat/features/chat/chat_controller.dart';
import 'package:cp_chat/features/chat/conversation_metadata.dart';
import 'package:cp_chat/features/groups/group_controller.dart';
import 'package:cp_chat/features/people/people_controller.dart';
import 'package:cp_chat/features/presence/presence_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);
}

class _TestAuth extends AuthController {
  @override
  AuthState build() => const AuthState.unauthenticated();

  void signIn(String userId) {
    state = AuthState.authenticated(
      AuthSession(
        user: User(id: userId, name: userId),
        accessToken: 'tok-$userId',
        refreshToken: 'ref-$userId',
        expiresIn: 900,
      ),
    );
  }

  void signOut() {
    state = const AuthState.unauthenticated();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Architecture guards (§Phase 3)', () {
    test('every user-bound provider rebuilds / disposes when accountScopeProvider changes', () async {
      final root = await Directory.systemTemp.createTemp('cpchat_guard_');
      addTearDown(() => root.delete(recursive: true));
      final dirs = AppDirs.forTesting(root);
      await dirs.initialize();
      final store = _MapTokenStore();

      final container = ProviderContainer(
        overrides: [
          appDirsProvider.overrideWithValue(dirs),
          tokenStoreProvider.overrideWithValue(store),
          authControllerProvider.overrideWith(_TestAuth.new),
        ],
      );
      addTearDown(container.dispose);

      final auth = container.read(authControllerProvider.notifier) as _TestAuth;
      auth.signIn('user-a');

      final scopeA = container.read(accountScopeProvider);
      final dbA = container.read(appDatabaseProvider);
      final daoA = container.read(chatDaoProvider);
      final apiA = container.read(apiClientProvider);
      final mediaA = container.read(mediaServiceProvider);
      final cacheA = container.read(mediaCacheProvider);
      final e2eeA = container.read(e2eeManagerProvider);
      final socketA = container.read(chatSocketProvider);
      final pushA = container.read(pushRegistrationProvider);
      final notifierA = container.read(messageNotifierProvider);
      final accountStoreA = container.read(accountStoreProvider);
      final groupCtrlA = container.read(groupControllerProvider);
      final chatCtrlA = container.read(chatControllerProvider('conv-1'));
      final callMediaA = container.read(livekitMediaServiceProvider);

      container.read(activeGroupCallsProvider.notifier).upsert(
            ActiveCallSummary(
              callId: 'call-a',
              conversationId: 'group-a',
              roomName: 'call_call-a',
              type: CallType.group,
              mediaType: CallMediaType.voice,
              initiatedBy: 'user-a',
              status: 'active',
              participantCount: 1,
              participantIds: const ['user-a'],
              startedAt: DateTime.now().toUtc(),
            ),
          );
      expect(container.read(activeGroupCallsProvider), isNotEmpty);

      container.read(activeConversationIdProvider.notifier).open('conv-1');
      expect(container.read(activeConversationIdProvider), 'conv-1');

      container.read(peopleControllerProvider.notifier).updateQuery('ali');
      expect(container.read(peopleControllerProvider).query, 'ali');

      // Switch to user B.
      auth.signOut();
      expect(container.read(accountScopeProvider), isNull);
      expect(scopeA!.isOpen, isFalse);
      expect(container.read(activeConversationIdProvider), isNull);

      auth.signIn('user-b');

      final scopeB = container.read(accountScopeProvider);
      final dbB = container.read(appDatabaseProvider);
      final daoB = container.read(chatDaoProvider);
      final apiB = container.read(apiClientProvider);
      final mediaB = container.read(mediaServiceProvider);
      final cacheB = container.read(mediaCacheProvider);
      final e2eeB = container.read(e2eeManagerProvider);
      final socketB = container.read(chatSocketProvider);
      final pushB = container.read(pushRegistrationProvider);
      final notifierB = container.read(messageNotifierProvider);
      final accountStoreB = container.read(accountStoreProvider);
      final groupCtrlB = container.read(groupControllerProvider);
      final chatCtrlB = container.read(chatControllerProvider('conv-1'));
      final callMediaB = container.read(livekitMediaServiceProvider);

      expect(identical(scopeA, scopeB), isFalse);
      expect(identical(dbA, dbB), isFalse);
      expect(identical(daoA, daoB), isFalse);
      expect(identical(apiA, apiB), isFalse);
      expect(identical(mediaA, mediaB), isFalse);
      expect(identical(cacheA, cacheB), isFalse);
      expect(identical(e2eeA, e2eeB), isFalse);
      expect(identical(socketA, socketB), isFalse);
      expect(identical(pushA, pushB), isFalse);
      expect(identical(notifierA, notifierB), isFalse);
      expect(identical(accountStoreA, accountStoreB), isFalse);
      expect(identical(groupCtrlA, groupCtrlB), isFalse);
      expect(identical(chatCtrlA, chatCtrlB), isFalse);
      expect(identical(callMediaA, callMediaB), isFalse);
      expect(container.read(activeGroupCallsProvider), isEmpty);
      expect(container.read(callControllerProvider).isIdle, isTrue);
      expect(container.read(peopleControllerProvider).query, isEmpty);

      // Verify presence / conversationMetadata / friends / userProfile / calls
      // source files explicitly watch accountScopeProvider.
      final providerFiles = [
        'lib/features/presence/presence_controller.dart',
        'lib/features/people/people_controller.dart',
        'lib/features/chat/conversation_metadata.dart',
        'lib/features/groups/group_controller.dart',
        'lib/features/chat/chat_controller.dart',
        'lib/features/calls/call_controller.dart',
      ];
      for (final path in providerFiles) {
        final content = File(path).readAsStringSync();
        expect(
          content,
          contains('accountScopeProvider'),
          reason: '$path must watch accountScopeProvider so state resets on switch',
        );
      }

      // Silence unused imports of feature providers tested via source check.
      expect(presenceProvider, isNotNull);
      expect(friendsProvider, isNotNull);
      expect(userProfileProvider, isNotNull);
      expect(conversationMetadataProvider, isNotNull);
    });

    test('banned unscoped APIs do not appear outside their owning modules', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue);

      final dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
          .toList();

      for (final file in dartFiles) {
        final rel = file.path.replaceAll('\\', '/');
        final content = file.readAsStringSync();

        if (!rel.endsWith('lib/core/storage/token_store.dart')) {
          expect(
            content,
            isNot(contains('FlutterSecureStorage(')),
            reason: 'FlutterSecureStorage( is only allowed in token_store.dart (found in $rel)',
          );
        }

        expect(
          content,
          isNot(contains('DefaultCacheManager')),
          reason: 'DefaultCacheManager is banned; use AccountMediaCache (found in $rel)',
        );

        if (!rel.endsWith('lib/core/storage/app_dirs.dart')) {
          expect(
            content,
            isNot(contains('getTemporaryDirectory')),
            reason: 'getTemporaryDirectory is only allowed in app_dirs.dart (found in $rel)',
          );
        }

        expect(
          content,
          isNot(contains('driftDatabase(')),
          reason: 'driftDatabase( is banned; use AppDatabase.forAccountLazy/forFile (found in $rel)',
        );
      }
    });
  });
}
