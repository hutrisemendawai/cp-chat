import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../storage/token_store.dart';

/// REST client for the CP Chat API.
///
/// Attaches the stored bearer token to every request. Refresh-token rotation
/// and retry-on-401 are implemented with the auth feature in Phase 1.
class ApiClient {
  ApiClient(
    this._tokenStore, {
    String baseUrl = AppConfig.apiBaseUrl,
    Dio? dio,
  })  : dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 20),
                contentType: Headers.jsonContentType,
              ),
            ) {
    this.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              final token = await _tokenStore.readAccessToken();
              if (token != null) {
                options.headers['Authorization'] = 'Bearer $token';
              }
              handler.next(options);
            },
          ),
        );
  }

  final TokenStore _tokenStore;
  final Dio dio;
}
