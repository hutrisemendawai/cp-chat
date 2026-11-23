import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../crypto/e2ee_service.dart' show PublicKeyBundle, PublicPrekey, RemotePrekeyBundle;
import '../config/app_config.dart';
import '../logging/app_logger.dart';
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
    AppLogger? logger,
  })  :
        // ignore: prefer_initializing_formals
        _logger = logger,
        dio = dio ??
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
            // Transport-level failures (offline, DNS, connection refused, time
            // out) are recorded for the shared timeline. HTTP error statuses
            // that reach a handler are normal domain responses and are not
            // logged here — logging every 4xx would drown the useful signal.
            //
            // Requests carrying `kSkipLogging` are the log submissions
            // themselves. Logging their failure would queue another submission,
            // whose failure would queue another: an endless loop while the
            // server is unreachable.
            onError: (error, handler) {
              if (error.requestOptions.extra[kSkipLogging] != true &&
                  _isTransportError(error)) {
                _logger?.networkError('dio', error);
              }
              handler.next(error);
            },
          ),
        );
  }

  /// True for failures in the request itself rather than a server response.
  static bool _isTransportError(DioException error) =>
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.unknown;

  static const kSkipAuth = 'skip_auth';
  static const kRetried = 'retried';

  /// Marks a request that must not itself be logged (the log submission path).
  static const kSkipLogging = 'skip_logging';

  final TokenStore _tokenStore;
  final Dio dio;
  final String? deviceId;
  final AppLogger? _logger;

  Future<bool>? _inFlightRefresh;

  /// Returns an access token that is valid for at least [leeway], refreshing it
  /// first when it is missing or about to expire.
  ///
  /// The WebSocket handshake is a plain HTTP upgrade, so an expired token there
  /// means a failed connection rather than a retryable 401. Proactively
  /// refreshing keeps reconnects from failing on a stale token, and the
  /// single-flight refresh means a concurrent REST call shares the rotation.
  Future<String?> ensureFreshAccessToken({
    Duration leeway = const Duration(seconds: 30),
  }) async {
    final token = await _tokenStore.readAccessToken();
    if (token == null) {
      return await refreshAccessToken() ? _tokenStore.readAccessToken() : null;
    }
    if (_isExpired(token, leeway)) {
      // A failed proactive refresh falls back to the current token; the server
      // is still authoritative and may accept a token we think is stale.
      if (await refreshAccessToken()) {
        return _tokenStore.readAccessToken();
      }
    }
    return token;
  }

  /// Forces one refresh-token rotation, sharing an in-flight rotation.
  Future<bool> refreshAccessToken() => _refreshOnce();

  /// Decodes a JWT's `exp` claim. A malformed or opaque token is treated as
  /// non-expiring so it is still tried rather than discarded.
  bool _isExpired(String token, Duration leeway) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic>) return false;
      final exp = payload['exp'];
      if (exp is! num) return false;
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true);
      return DateTime.now().toUtc().add(leeway).isAfter(expiry);
    } catch (_) {
      return false;
    }
  }

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

  /// Uploads media through the API instead of directly to object storage.
  ///
  /// The phone only has to reach [AppConfig.apiBaseUrl]; the API writes the
  /// bytes to storage server-side. This is what makes uploads work on a
  /// physical device that cannot reach the MinIO host directly.
  Future<MediaUpload> uploadMedia({
    required List<int> bytes,
    required String filename,
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final response = await dio.post<dynamic>(
      '/api/v1/media/upload',
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          Headers.contentTypeHeader: contentType,
          Headers.contentLengthHeader: bytes.length,
          'x-filename': filename,
        },
        // The upload route accepts a raw body, so skip the JSON content type
        // the client defaults to.
        contentType: contentType,
        // A 25 MB body over a slow link can outlast the default request budget.
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ),
      onSendProgress: onProgress,
    );
    final body = _ok(response, expected: 201);
    return MediaUpload.fromJson({
      ...body,
      'upload_url': body['file_url'],
      'expires_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Absolute URL the client can load the media from. The API authorizes the
  /// caller and streams the bytes back.
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

  /// Current online state for a user, used when a chat opens. Later changes
  /// arrive as `presence` frames over the WebSocket.
  Future<Presence> presence(String userId) async {
    final response = await dio.get<dynamic>('/api/v1/presence/$userId');
    return Presence.fromJson(_ok(response));
  }

  /// Full-text search inside a single conversation.
  Future<MessagePage> searchConversation(
    String conversationId,
    String query, {
    int limit = 30,
    int? beforeSeq,
  }) async {
    final response = await dio.get<dynamic>(
      '/api/v1/conversations/$conversationId/search',
      queryParameters: {
        'q': query,
        'limit': limit,
        'before_seq': ?beforeSeq,
      },
    );
    return MessagePage.fromJson(_ok(response));
  }

  /// Full-text search across every conversation the caller belongs to.
  Future<List<SearchHit>> search(
    String query, {
    int limit = 30,
    int? beforeSeq,
  }) async {
    final response = await dio.get<dynamic>(
      '/api/v1/search',
      queryParameters: {
        'q': query,
        'limit': limit,
        'before_seq': ?beforeSeq,
      },
    );
    final body = _ok(response);
    return (body['messages'] as List<dynamic>)
        .map((item) => SearchHit.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Publishes this device's public encryption keys. The server stores only
  /// public halves; private keys stay in secure storage on the device.
  Future<int> publishKeys(PublicKeyBundle bundle) async {
    final response = await dio.post<dynamic>(
      '/api/v1/keys',
      data: {
        'identity_key': bundle.identityKey,
        'signing_key': bundle.signingKey,
        'signed_prekey': {
          'key_id': bundle.signedPrekeyId,
          'public_key': bundle.signedPrekey,
          'signature': bundle.signedPrekeySignature,
        },
        'one_time_prekeys': [
          for (final prekey in bundle.prekeys)
            {'key_id': prekey.keyId, 'public_key': prekey.publicKey},
        ],
      },
    );
    final body = _ok(response, expected: 201);
    return (body['one_time_prekeys'] as num?)?.toInt() ?? 0;
  }

  /// Tops up one-time prekeys without re-publishing the identity keys.
  Future<int> addPrekeys(List<PublicPrekey> prekeys) async {
    final response = await dio.post<dynamic>(
      '/api/v1/keys/prekeys',
      data: {
        'one_time_prekeys': [
          for (final prekey in prekeys)
            {'key_id': prekey.keyId, 'public_key': prekey.publicKey},
        ],
      },
    );
    final body = _ok(response);
    return (body['one_time_prekeys'] as num?)?.toInt() ?? 0;
  }

  /// Fetches a peer's prekey bundle. The server consumes one one-time prekey
  /// per call, so callers must initiate a session rather than retry blindly.
  Future<RemotePrekeyBundle> prekeyBundle(String userId) async {
    final response = await dio.get<dynamic>('/api/v1/keys/$userId');
    final body = _ok(response);
    final signed = body['signed_prekey'] as Map<String, dynamic>;
    final oneTime = body['one_time_prekey'] as Map<String, dynamic>?;
    return RemotePrekeyBundle(
      userId: body['user_id'] as String,
      identityKey: body['identity_key'] as String,
      signingKey: body['signing_key'] as String,
      signedPrekeyId: (signed['key_id'] as num).toInt(),
      signedPrekey: signed['public_key'] as String,
      signedPrekeySignature: signed['signature'] as String,
      oneTimePrekeyId: (oneTime?['key_id'] as num?)?.toInt(),
      oneTimePrekey: oneTime?['public_key'] as String?,
    );
  }

  /// The caller's own published key status, including how many one-time
  /// prekeys the server still holds. Used to decide when to top up.
  Future<int> myPrekeyCount() async {
    final response = await dio.get<dynamic>('/api/v1/keys/me');
    final body = _ok(response);
    return (body['one_time_prekeys'] as num?)?.toInt() ?? 0;
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

  /// Forwards a client diagnostic entry to the shared 1-hour log timeline.
  ///
  /// Returns `false` on any failure. The caller (AppLogger) is fire-and-forget,
  /// so a failed submission must never surface as an error or be retried by the
  /// logger itself.
  Future<bool> logClientEntry(AppLogEntry entry) async {
    try {
      final response = await dio.post<dynamic>(
        '/api/v1/logs/client',
        data: entry.toRequestJson(),
        options: Options(
          extra: {kSkipLogging: true},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      return (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300;
    } catch (_) {
      return false;
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

  /// Re-serializes a decoded response body so [ApiException.fromResponse] can
  /// read the `error` object. Dio decodes JSON into a Map, and Map#toString is
  /// not valid JSON (unquoted keys), which made every typed error fall back to
  /// a generic `Request failed (<status>)`.
  String _body(dynamic data) {
    if (data == null) return '';
    if (data is String) return data;
    try {
      return jsonEncode(data);
    } catch (_) {
      return data.toString();
    }
  }

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
