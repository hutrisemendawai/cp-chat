import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists JWT access/refresh tokens in the Android Keystore-backed storage,
/// plus the stable per-install device id used for connection routing.
class TokenStore {
  TokenStore([this._storage = const FlutterSecureStorage()]);

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _deviceIdKey = 'device_id';

  final FlutterSecureStorage _storage;

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<String?> readUserId() => _storage.read(key: _userIdKey);

  /// The device id survives logout so the gateway keeps a stable routing key.
  Future<String?> readDeviceId() => _storage.read(key: _deviceIdKey);

  Future<void> writeDeviceId(String deviceId) =>
      _storage.write(key: _deviceIdKey, value: deviceId);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    await saveTokens(accessToken: accessToken, refreshToken: refreshToken);
    await _storage.write(key: _userIdKey, value: userId);
  }

  /// Clears the session but keeps the device id.
  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _userIdKey);
  }

  Future<bool> hasSession() async {
    final access = await readAccessToken();
    final refresh = await readRefreshToken();
    return access != null || refresh != null;
  }
}
