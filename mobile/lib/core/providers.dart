import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'database/app_database.dart';
import 'database/chat_dao.dart';
import 'media/media_service.dart';
import 'models/models.dart';
import 'network/api_client.dart';
import 'network/ws_client.dart';
import 'notifications/fcm_service.dart';
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
  return ApiClient(
    ref.watch(tokenStoreProvider),
    deviceId: ref.watch(deviceIdProvider),
  );
});

final mediaServiceProvider = Provider<MediaService>((ref) {
  return MediaService(ref.watch(apiClientProvider));
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
  );
  ref.onDispose(socket.dispose);
  return socket;
});

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

  Future<void> logout() async {
    final api = ref.read(apiClientProvider);
    await api.logout();
    await ref.read(chatDaoProvider).clearAll();
    state = null;
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
