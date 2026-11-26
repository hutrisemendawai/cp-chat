import 'dart:convert';

import '../storage/token_store.dart';

/// Queued server-side clear operations persisted when L1 clear runs offline.
class PendingServerClear {
  const PendingServerClear({
    this.clearAll = false,
    this.conversationIds = const [],
  });

  factory PendingServerClear.fromJson(Map<String, dynamic> json) => PendingServerClear(
        clearAll: json['all'] as bool? ?? false,
        conversationIds: (json['conversations'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
      );

  final bool clearAll;
  final List<String> conversationIds;

  bool get isEmpty => !clearAll && conversationIds.isEmpty;

  Map<String, dynamic> toJson() => {
        'all': clearAll,
        'conversations': conversationIds,
      };
}

/// Account-namespaced secure-storage facade (`acct.<accountId>.*`).
///
/// Isolates E2EE identity keys, ratchet sessions, partition integrity markers,
/// and offline clear queues strictly per account so switching users on the same
/// device can never read or overwrite another user's cryptographic material.
class AccountStore {
  AccountStore(this._tokenStore, this.accountId);

  final TokenStore _tokenStore;
  final String accountId;

  String get _prefix => 'acct.$accountId.';
  String get e2eeKeysKey => '${_prefix}e2ee_keys';
  String get e2eeSessionsKey => '${_prefix}e2ee_sessions';
  String get partitionIdKey => '${_prefix}partition_id';
  String get pendingServerClearKey => '${_prefix}pending_server_clear';
  String get freshPromptPendingKey => '${_prefix}fresh_prompt_pending';

  Future<String?> readE2eeKeys() => _tokenStore.readValue(e2eeKeysKey);

  Future<void> writeE2eeKeys(String json) => _tokenStore.writeValue(e2eeKeysKey, json);

  Future<String?> readE2eeSessions() => _tokenStore.readValue(e2eeSessionsKey);

  Future<void> writeE2eeSessions(String json) =>
      _tokenStore.writeValue(e2eeSessionsKey, json);

  Future<void> deleteE2ee() async {
    await _tokenStore.deleteValue(e2eeKeysKey);
    await _tokenStore.deleteValue(e2eeSessionsKey);
  }

  Future<String?> readPartitionId() => _tokenStore.readValue(partitionIdKey);

  Future<void> writePartitionId(String id) =>
      _tokenStore.writeValue(partitionIdKey, id);

  Future<PendingServerClear> readPendingServerClear() async {
    final raw = await _tokenStore.readValue(pendingServerClearKey);
    if (raw == null || raw.isEmpty) return const PendingServerClear();
    try {
      return PendingServerClear.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const PendingServerClear();
    }
  }

  Future<void> writePendingServerClear(PendingServerClear pending) async {
    if (pending.isEmpty) {
      await _tokenStore.deleteValue(pendingServerClearKey);
    } else {
      await _tokenStore.writeValue(pendingServerClearKey, jsonEncode(pending.toJson()));
    }
  }

  Future<void> addPendingConversationClear(String conversationId) async {
    final current = await readPendingServerClear();
    if (current.clearAll) return;
    final ids = {...current.conversationIds, conversationId}.toList();
    await writePendingServerClear(PendingServerClear(conversationIds: ids));
  }

  Future<void> setPendingClearAll() async {
    await writePendingServerClear(const PendingServerClear(clearAll: true));
  }

  Future<void> clearPendingServerClear() =>
      _tokenStore.deleteValue(pendingServerClearKey);

  Future<bool> readFreshPromptPending() async {
    return (await _tokenStore.readValue(freshPromptPendingKey)) == '1';
  }

  Future<void> writeFreshPromptPending(bool pending) async {
    if (pending) {
      await _tokenStore.writeValue(freshPromptPendingKey, '1');
    } else {
      await _tokenStore.deleteValue(freshPromptPendingKey);
    }
  }

  /// Removes every key belonging to this account partition (L2 wipe).
  Future<void> deleteAll() async {
    await _tokenStore.deleteValue(e2eeKeysKey);
    await _tokenStore.deleteValue(e2eeSessionsKey);
    await _tokenStore.deleteValue(partitionIdKey);
    await _tokenStore.deleteValue(pendingServerClearKey);
    await _tokenStore.deleteValue(freshPromptPendingKey);
  }
}
