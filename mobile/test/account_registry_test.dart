import 'package:cp_chat/core/account/account_id.dart';
import 'package:cp_chat/core/account/account_registry.dart';
import 'package:cp_chat/core/storage/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MapTokenStore extends TokenStore {
  final Map<String, String> data = {};

  @override
  Future<String?> readValue(String key) async => data[key];

  @override
  Future<void> writeValue(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteValue(String key) async => data.remove(key);

  @override
  Future<Map<String, String>> readAllValues() async => Map.of(data);
}

void main() {
  group('AccountRegistry', () {
    test('registers idempotently, sorts by lastActiveAt, and removes entries', () async {
      var now = DateTime.utc(2026, 11, 26, 10, 0);
      final store = _MapTokenStore();
      final registry = AccountRegistry(store, clock: () => now);

      final a1 = await registry.register('user-a', displayName: 'Alice', username: 'alice');
      now = now.add(const Duration(minutes: 5));
      final b = await registry.register('user-b', displayName: 'Bob', username: 'bob');
      now = now.add(const Duration(minutes: 5));
      final a2 = await registry.register('user-a');

      expect(a1.accountId, accountIdForUser('user-a'));
      expect(a2.accountId, a1.accountId);
      // Preserves previously known displayName/username when omitted.
      expect(a2.displayName, 'Alice');
      expect(a2.username, 'alice');

      final listed = await registry.list();
      expect(listed.map((r) => r.userId).toList(), ['user-a', 'user-b']);
      expect((await registry.findByUserId('user-b'))?.accountId, b.accountId);

      await registry.remove(b.accountId);
      expect((await registry.list()).map((r) => r.userId).toList(), ['user-a']);
    });

    test('tracks crash-resumable wipe_pending and pending_l2_clear flags', () async {
      final store = _MapTokenStore();
      final registry = AccountRegistry(store);
      final idA = accountIdForUser('user-a');

      await registry.markWipePending(idA);
      expect(await registry.pendingWipes(), [idA]);

      await registry.clearWipePending(idA);
      expect(await registry.pendingWipes(), isEmpty);

      expect(await registry.hasPendingL2ServerClear(idA), isFalse);
      await registry.setPendingL2ServerClear(idA, true);
      expect(await registry.hasPendingL2ServerClear(idA), isTrue);
      await registry.setPendingL2ServerClear(idA, false);
      expect(await registry.hasPendingL2ServerClear(idA), isFalse);
    });
  });
}
