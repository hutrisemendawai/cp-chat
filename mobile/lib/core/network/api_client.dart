import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import '../storage/token_store.dart';

/// REST client for the CP Chat API.
///
/// Attaches the stored bearer token to every request. A 401 triggers a single
/// refresh-token rotation and one retry; concurrent 401s share that rotation so
/// the refresh token is never presented twice (the server revokes the whole
/// family on reuse).
class ApiClient {
  ApiClient(
    this._tokenStore, {
    String baseUrl = AppConfig.apiBaseUrl,
    Dio? dio,
    this.deviceId,
  }) : dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 20),
                contentType: Headers.jsonContentType,
                // Handle every status in code so the refresh interceptor can
                // see 401s instead of Dio throwing before it runs.
                validateStatus: (status) => status != null && status < 500,
              ),
            ) {
    this.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.extra[kSkipAuth] != true) {
                final token = await _tokenStore.readAccessToken();
                if (token != null) {
                  options.headers['Authorization'] = 'Bearer $token';
                }
              }
              final device = deviceId;
              if (device != null) options.headers['x-device-id'] = device;
              handler.next(options);
            },
            onResponse: (response, handler) async {
              if (response.statusCode != 401 || response.requestOptions.extra[kSkipAuth] == true) {
                handler.next(response);
                return;
              }
              if (response.requestOptions.extra[kRetried] == true) {
                handler.next(response);
                return;
              }

              final refreshed = await _refreshOnce();
              if (!refreshed) {
                handler.next(response);
                return;
              }

              final retryOptions = response.requestOptions
                ..extra[kRetried] = true
                ..headers['Authorization'] = 'Bearer ${await _tokenStore.readAccessToken()}';
              try {
                handler.resolve(await this.dio.fetch(retryOptions));
              } catch (error) {
                handler.reject(error is DioException ? error : DioException(requestOptions: retryOptions, error: error));
              }
            },
            onError: (error, handler) => handler.next(error),
          ),
        );
  }

  static const kSkipAuth = 'skip_auth';
  static const kRetried = 'retried';

  final TokenStore _tokenStore;
  final Dio dio;
  final String? deviceId;

  Future<bool>? _inFlightRefresh;

  /// Authenticates and persists the session.
  Future<AuthSession> register({
    required String phoneOrEmail,
    required String name,
    required String password,
  }) async {
    final session = await _postSession(
      '/api/v1/auth/register',
      {'phone_or_email': phoneOrEmail, 'name': name, 'password': password},
      expected: 201,
    );
    await _tokenStore.saveSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: session.user.id,
    );
    return session;
  }

  Future<AuthSession> login({
    required String phoneOrEmail,
    required String password,
  }) async {
    final session = await _postSession(
      '/api/v1/auth/login',
      {'phone_or_email': phoneOrEmail, 'password': password},
    );
    await _tokenStore.saveSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: session.user.id,
    );
    return session;
  }

  Future<void> logout() async {
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken != null) {
      try {
        await dio.post<void>(
          '/api/v1/auth/logout',
          data: {'refresh_token': refreshToken},
          options: Options(validateStatus: (status) => status != null && status < 500),
        );
      } catch (_) {
        // Best effort: local logout always succeeds.
      }
    }
    await _tokenStore.clear();
  }

  Future<User> me() async {
    final response = await dio.get<dynamic>('/api/v1/users/me');
    return User.fromJson(_ok(response));
  }

  Future<User> user(String id) async {
    final response = await dio.get<dynamic>('/api/v1/users/$id');
    return User.fromJson(_ok(response));
  }

  Future<List<Conversation>> conversations({int limit = 50}) async {
    final response = await dio.get<dynamic>(
      '/api/v1/conversations',
      queryParameters: {'limit': limit},
    );
    final body = _ok(response);
    return (body['conversations'] as List<dynamic>)
        .map((item) => Conversation.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> conversation(String id) async {
    final response = await dio.get<dynamic>('/api/v1/conversations/$id');
    return Conversation.fromJson(_ok(response));
  }

  Future<Conversation> createDirectConversation(String otherUserId) async {
    final response = await dio.post<dynamic>(
      '/api/v1/conversations',
      data: {
        'type': 'direct',
        'member_ids': [otherUserId],
      },
    );
    return Conversation.fromJson(_ok(response, expected: 201));
  }

  /// Creates a group. The caller becomes the sole admin.
  Future<Conversation> createGroupConversation({
    required String name,
    required List<String> memberIds,
    String? avatarKey,
  }) async {
    final response = await dio.post<dynamic>(
      '/api/v1/conversations',
      data: {
        'type': 'group',
        'name': name,
        'member_ids': memberIds,
        'avatar_url': ?avatarKey,
      },
    );
    return Conversation.fromJson(_ok(response, expected: 201));
  }

  /// Updates a group's name or avatar. Omit a field to leave it unchanged; pass
  /// [clearAvatar] to remove the current avatar.
  Future<Conversation> updateGroup(
    String conversationId, {
    String? name,
    String? avatarKey,
    bool clearAvatar = false,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (clearAvatar) {
      payload['avatar_url'] = null;
    } else if (avatarKey != null) {
      payload['avatar_url'] = avatarKey;
    }

    final response = await dio.patch<dynamic>(
      '/api/v1/conversations/$conversationId',
      data: payload,
    );
    return Conversation.fromJson(_ok(response));
  }

  Future<List<ConversationMember>> addGroupMembers(
    String conversationId,
    List<String> userIds,
  ) async {
    final response = await dio.post<dynamic>(
      '/api/v1/conversations/$conversationId/members',
      data: {'user_ids': userIds},
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw ApiException.fromResponse(status, _body(response.data));
    }
    final list = response.data is List<dynamic> ? response.data as List<dynamic> : <dynamic>[];
    return list
        .map((member) => ConversationMember.fromJson(member as Map<String, dynamic>))
        .toList();
  }

  /// Removes a member. Calling with the current user's id leaves the group.
  Future<void> removeGroupMember(String conversationId, String userId) async {
    final response = await dio.delete<dynamic>(
      '/api/v1/conversations/$conversationId/members/$userId',
      options: Options(validateStatus: (status) => status != null && status < 500),
    );
    final status = response.statusCode ?? 0;
    if (status != 204) {
      throw ApiException.fromResponse(status, _body(response.data));
    }
  }

  /// Requests a presigned upload slot for a media object.
  Future<MediaUpload> presignUpload({
    required String filename,
    required String contentType,
    required int sizeBytes,
  }) async {
    final response = await dio.post<dynamic>(
      '/api/v1/media/presign',
      data: {
        'filename': filename,
        'content_type': contentType,
        'size_bytes': sizeBytes,
      },
    );
    return MediaUpload.fromJson(_ok(response, expected: 201));
  }

  /// Uploads bytes straight to object storage using the presigned PUT. The
  /// `Content-Type` must match what was declared when presigning or the
  /// signature is rejected.
  Future<void> uploadToPresignedUrl({
    required String uploadUrl,
    required List<int> bytes,
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final uploader = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 120),
      ),
    );
    final response = await uploader.put<void>(
      uploadUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          Headers.contentTypeHeader: contentType,
          Headers.contentLengthHeader: bytes.length,
        },
        // Presigned S3 URLs must not carry the API bearer token.
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
      ),
      onSendProgress: onProgress,
    );
    if ((response.statusCode ?? 0) >= 300) {
      throw ApiException('upload_failed', 'Upload failed (${response.statusCode})');
    }
  }

  /// Absolute URL the client can load the media from. The API authorizes the
  /// caller and redirects to a short-lived presigned download.
  String mediaUrl(String objectKey) => '${dio.options.baseUrl}/api/v1/media/$objectKey';

  Future<MessagePage> messages(
    String conversationId, {
    int? beforeSeq,
    int limit = 50,
  }) async {
    final response = await dio.get<dynamic>(
      '/api/v1/conversations/$conversationId/messages',
      queryParameters: {
        'before_seq': ?beforeSeq,
        'limit': limit,
      },
    );
    return MessagePage.fromJson(_ok(response));
  }

  Future<SyncResult> sync(String conversationId, {required int afterSeq, int limit = 200}) async {
    final response = await dio.get<dynamic>(
      '/api/v1/conversations/$conversationId/sync',
      queryParameters: {'after_seq': afterSeq, 'limit': limit},
    );
    return SyncResult.fromJson(_ok(response));
  }

  /// Registers the Firebase Installation ID for push delivery.
  Future<void> registerFcmToken(String fid) async {
    final response = await dio.post<dynamic>(
      '/api/v1/devices/fcm-token',
      data: {'fcm_token': fid, if (deviceId != null) 'device_id': deviceId},
      options: Options(validateStatus: (status) => status != null && status < 500),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ApiException.fromResponse(response.statusCode ?? 0, _body(response.data));
    }
  }

  Future<void> unregisterFcmToken() async {
    final response = await dio.delete<dynamic>(
      '/api/v1/devices/fcm-token',
      options: Options(validateStatus: (status) => status != null && status < 500),
    );
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw ApiException.fromResponse(response.statusCode ?? 0, _body(response.data));
    }
  }

  Future<AuthSession> _postSession(
    String path,
    Map<String, dynamic> payload, {
    int expected = 200,
  }) async {
    final response = await dio.post<dynamic>(
      path,
      data: payload,
      options: Options(extra: {kSkipAuth: true}),
    );
    return AuthSession.fromJson(_ok(response, expected: expected));
  }

  /// Returns the JSON body or throws a typed [ApiException].
  Map<String, dynamic> _ok(Response<dynamic> response, {int? expected}) {
    final status = response.statusCode ?? 0;
    final okStatus = expected == null ? (status >= 200 && status < 300) : status == expected;
    if (!okStatus) {
      throw ApiException.fromResponse(status, _body(response.data));
    }
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
    }
    return <String, dynamic>{};
  }

  String _body(dynamic data) => data is String ? data : (data == null ? '' : data.toString());

  /// Single-flight refresh: the first caller rotates, everyone else awaits the
  /// same rotation. The server revokes the whole token family on reuse, so two
  /// concurrent rotations would sign the user out.
  Future<bool> _refreshOnce() {
    final inFlight = _inFlightRefresh;
    if (inFlight != null) {
      return inFlight.then((ok) => ok);
    }

    final future = _performRefresh();
    _inFlightRefresh = future;
    return future.whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<bool> _performRefresh() async {
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken == null) return false;

    try {
      final response = await dio.post<dynamic>(
        '/api/v1/auth/refresh',
        data: {'refresh_token': refreshToken, if (deviceId != null) 'device_id': deviceId},
        options: Options(
          extra: {kSkipAuth: true},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if (response.statusCode != 200) {
        await _tokenStore.clear();
        return false;
      }
      final pair = TokenPair.fromJson(response.data as Map<String, dynamic>);
      await _tokenStore.saveTokens(
        accessToken: pair.accessToken,
        refreshToken: pair.refreshToken,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
