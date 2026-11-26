import 'dart:convert';

import '../storage/token_store.dart';
import 'account_id.dart';

/// One known local account partition stored on this device.
class AccountRecord {
  const AccountRecord({
    required this.accountId,
    required this.userId,
    required this.lastActiveAt,
    this.displayName,
    this.username,
  });

  factory AccountRecord.fromJson(Map<String, dynamic> json) => AccountRecord(
        accountId: json['accountId'] as String,
        userId: json['userId'] as String,
        lastActiveAt: DateTime.parse(json['lastActiveAt'] as String).toUtc(),
        displayName: json['displayName'] as String?,
        username: json['username'] as String?,
      );

  final String accountId;
  final String userId;
  final DateTime lastActiveAt;
  final String? displayName;
  final String? username;

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'userId': userId,
        'lastActiveAt': lastActiveAt.toUtc().toIso8601String(),
        if (displayName != null) 'displayName': displayName,
        if (username != null) 'username': username,
      };
}

/// Device-global registry of local account partitions and crash-resumable
/// pending-wipe markers. Stored in Keystore-backed [TokenStore].
class AccountRegistry {
  AccountRegistry(this._tokenStore, {DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc());

  static const _indexKey = 'accounts_index';
  static const _pendingWipesKey = 'wipe_pending_accounts';
  static String _wipePendingKey(String accountId) => 'wipe_pending.$accountId';
  static String _pendingL2ServerClearKey(String accountId) =>
      'pending_l2_clear.$accountId';

  final TokenStore _tokenStore;
  final DateTime Function() _clock;

  Future<List<AccountRecord>> list() async {
    final raw = await _tokenStore.readValue(_indexKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AccountRecord.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<AccountRecord?> findByAccountId(String accountId) async {
    final records = await list();
    for (final record in records) {
      if (record.accountId == accountId) return record;
    }
    return null;
  }

  Future<AccountRecord?> findByUserId(String userId) async {
    return findByAccountId(accountIdForUser(userId));
  }

  /// Idempotently registers or updates [userId] in the device index.
  Future<AccountRecord> register(
    String userId, {
    String? displayName,
    String? username,
  }) async {
    final accountId = accountIdForUser(userId);
    final records = (await list()).toList();
    final existingIdx = records.indexWhere((r) => r.accountId == accountId);
    final existing = existingIdx >= 0 ? records[existingIdx] : null;
    final updated = AccountRecord(
      accountId: accountId,
      userId: userId,
      lastActiveAt: _clock(),
      displayName: displayName ?? existing?.displayName,
      username: username ?? existing?.username,
    );
    if (existingIdx >= 0) {
      records[existingIdx] = updated;
    } else {
      records.add(updated);
    }
    records.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
    await _save(records);
    return updated;
  }

  Future<void> remove(String accountId) async {
    final records = (await list()).toList()
      ..removeWhere((r) => r.accountId == accountId);
    await _save(records);
  }

  Future<void> _save(List<AccountRecord> records) async {
    await _tokenStore.writeValue(
      _indexKey,
      jsonEncode(records.map((r) => r.toJson()).toList()),
    );
  }

  /// Marks [accountId] as having an in-flight L2 wipe so a crash mid-delete is
  /// completed by the janitor on next launch.
  Future<void> markWipePending(String accountId) async {
    await _tokenStore.writeValue(_wipePendingKey(accountId), '1');
    final pending = (await pendingWipes()).toSet()..add(accountId);
    await _tokenStore.writeValue(_pendingWipesKey, jsonEncode(pending.toList()));
  }

  Future<void> clearWipePending(String accountId) async {
    await _tokenStore.deleteValue(_wipePendingKey(accountId));
    final pending = (await pendingWipes()).toSet()..remove(accountId);
    if (pending.isEmpty) {
      await _tokenStore.deleteValue(_pendingWipesKey);
    } else {
      await _tokenStore.writeValue(_pendingWipesKey, jsonEncode(pending.toList()));
    }
  }

  Future<List<String>> pendingWipes() async {
    final raw = await _tokenStore.readValue(_pendingWipesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Survives L2 partition deletion when the user reset offline; consumed on
  /// that user's next authenticated login before `syncAll`.
  Future<void> setPendingL2ServerClear(String accountId, bool pending) async {
    if (pending) {
      await _tokenStore.writeValue(_pendingL2ServerClearKey(accountId), '1');
    } else {
      await _tokenStore.deleteValue(_pendingL2ServerClearKey(accountId));
    }
  }

  Future<bool> hasPendingL2ServerClear(String accountId) async {
    return (await _tokenStore.readValue(_pendingL2ServerClearKey(accountId))) == '1';
  }
}
