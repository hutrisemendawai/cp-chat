import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists JWT access/refresh tokens in the Android Keystore-backed storage,
/// plus the stable per-install device id used for connection routing.
class TokenStore {
  TokenStore([this._storage = const FlutterSecureStorage()]);

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _deviceIdKey = 'device_id';
  static const _e2eeKeysKey = 'e2ee_keys';
  static const _e2eeSessionsKey = 'e2ee_sessions';

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

  /// Clears the session but keeps the device id and encryption keys.
  ///
  /// E2EE keys are per-device and survive logout: discarding them would make
  /// every existing session unreadable and would orphan published prekeys.
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

  /// Raw serialised private key material, encrypted at rest by the Android
  /// Keystore-backed storage. `null` when this device has not yet generated
  /// keys.
  Future<String?> readE2eeKeys() => _storage.read(key: _e2eeKeysKey);

  Future<void> writeE2eeKeys(String json) => _storage.write(key: _e2eeKeysKey, value: json);

  /// Serialised per-peer ratchet sessions.
  Future<String?> readE2eeSessions() => _storage.read(key: _e2eeSessionsKey);

  Future<void> writeE2eeSessions(String json) =>
      _storage.write(key: _e2eeSessionsKey, value: json);

  /// Removes identity keys and sessions. Only for a deliberate key reset.
  Future<void> clearE2ee() async {
    await _storage.delete(key: _e2eeKeysKey);
    await _storage.delete(key: _e2eeSessionsKey);
  }
}
