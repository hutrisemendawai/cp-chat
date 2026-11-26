import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

/// Persists JWT access/refresh tokens in Android Keystore-backed storage,
/// plus the stable per-install device id used for connection routing and the
/// cached profile of the signed-in user.
///
/// Every read is guarded against [PlatformException] (for example after an OS
/// backup restore whose Keystore master key is missing or after a credential
/// reset). On such a failure the store reports `null` rather than crashing so
/// cold start cleanly treats the device as signed out with a fresh partition.
class TokenStore {
  TokenStore([
    FlutterSecureStorage? storage,
    this.onStorageError,
  ]) : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(resetOnError: true),
            );

  /// Safe constructor for headless background isolates (FCM handlers).
  ///
  /// Uses `resetOnError: false` so a transient Android Keystore lock or Direct
  /// Boot (Before First Unlock) error simply returns `null` rather than wiping
  /// the user's session tokens and E2EE private keys.
  factory TokenStore.forBackground({
    void Function(String op, String key, Object error)? onStorageError,
  }) =>
      TokenStore(
        const FlutterSecureStorage(
          aOptions: AndroidOptions(resetOnError: false),
        ),
        onStorageError,
      );

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _userKey = 'user_profile';
  static const _deviceIdKey = 'device_id';
  static const _activeAccountIdKey = 'active_account_id';
  static const _resolvedNoBackupRootKey = 'resolved_no_backup_root';

  /// Legacy global E2EE keys (pre-partition layout). Read/deleted during
  /// migration or by callers that have not yet switched to `AccountStore`.
  static const legacyE2eeKeysKey = 'e2ee_keys';
  static const legacyE2eeSessionsKey = 'e2ee_sessions';

  final FlutterSecureStorage _storage;
  final void Function(String op, String key, Object error)? onStorageError;

  Future<String?> readValue(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (error) {
      _reportError('read', key, error);
      return null;
    } on MissingPluginException catch (error) {
      _reportError('read', key, error);
      return null;
    }
  }

  Future<void> writeValue(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (error) {
      _reportError('write', key, error);
    } on MissingPluginException catch (error) {
      _reportError('write', key, error);
    }
  }

  Future<void> deleteValue(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException catch (error) {
      _reportError('delete', key, error);
    } on MissingPluginException catch (error) {
      _reportError('delete', key, error);
    }
  }

  Future<Map<String, String>> readAllValues() async {
    try {
      return await _storage.readAll();
    } on PlatformException catch (error) {
      _reportError('readAll', '*', error);
      return const {};
    } on MissingPluginException catch (error) {
      _reportError('readAll', '*', error);
      return const {};
    }
  }

  void _reportError(String op, String key, Object error) {
    onStorageError?.call(op, key, error);
    debugPrint('TokenStore.$op($key) failed: $error');
  }

  Future<String?> readAccessToken() => readValue(_accessTokenKey);

  Future<String?> readRefreshToken() => readValue(_refreshTokenKey);

  Future<String?> readUserId() => readValue(_userIdKey);

  Future<String?> readActiveAccountId() => readValue(_activeAccountIdKey);

  Future<void> writeActiveAccountId(String? accountId) async {
    if (accountId == null) {
      await deleteValue(_activeAccountIdKey);
    } else {
      await writeValue(_activeAccountIdKey, accountId);
    }
  }

  /// Canonical Android `noBackupFilesDir` path cached during foreground startup
  /// for cross-checking in headless background isolates.
  Future<String?> readResolvedNoBackupRoot() =>
      readValue(_resolvedNoBackupRootKey);

  Future<void> writeResolvedNoBackupRoot(String path) =>
      writeValue(_resolvedNoBackupRootKey, path);

  /// The cached profile of the signed-in user, or `null` when none was stored
  /// (e.g. an install upgraded from a build that only persisted the user id).
  Future<User?> readUser() async {
    final raw = await readValue(_userKey);
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveUser(User user) =>
      writeValue(_userKey, jsonEncode(user.toJson()));

  /// The device id survives logout so the gateway keeps a stable routing key.
  Future<String?> readDeviceId() => readValue(_deviceIdKey);

  Future<void> writeDeviceId(String deviceId) =>
      writeValue(_deviceIdKey, deviceId);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await writeValue(_accessTokenKey, accessToken);
    await writeValue(_refreshTokenKey, refreshToken);
  }

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    required String userId,
    String? accountId,
  }) async {
    await saveTokens(accessToken: accessToken, refreshToken: refreshToken);
    await writeValue(_userIdKey, userId);
    if (accountId != null) {
      await writeValue(_activeAccountIdKey, accountId);
    }
  }

  /// Clears only the current session pointers. Does NOT delete the device id,
  /// account registry, or any per-account E2EE keys/sessions.
  Future<void> clear() async {
    await deleteValue(_accessTokenKey);
    await deleteValue(_refreshTokenKey);
    await deleteValue(_userIdKey);
    await deleteValue(_userKey);
    await deleteValue(_activeAccountIdKey);
  }

  /// Legacy global E2EE key blob. Kept for migration and backward-compatible
  /// tests; new code should use `AccountStore`.
  Future<String?> readE2eeKeys() => readValue(legacyE2eeKeysKey);

  Future<void> writeE2eeKeys(String json) => writeValue(legacyE2eeKeysKey, json);

  /// Legacy global E2EE sessions blob.
  Future<String?> readE2eeSessions() => readValue(legacyE2eeSessionsKey);

  Future<void> writeE2eeSessions(String json) =>
      writeValue(legacyE2eeSessionsKey, json);

  /// Removes legacy global E2EE keys and sessions.
  Future<void> clearE2ee() async {
    await deleteValue(legacyE2eeKeysKey);
    await deleteValue(legacyE2eeSessionsKey);
  }
}
