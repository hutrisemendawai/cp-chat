import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database/app_database.dart';
import 'network/api_client.dart';
import 'network/ws_client.dart';
import 'storage/token_store.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(tokenStoreProvider));
});

final chatSocketProvider = Provider<ChatSocket>((ref) {
  final tokenStore = ref.watch(tokenStoreProvider);
  final socket = ChatSocket(tokenStore.readAccessToken);
  ref.onDispose(socket.dispose);
  return socket;
});
