import 'package:cp_chat/core/account/account_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('accountIdForUser', () {
    test('returns a stable 16-char lowercase hex digest', () {
      final first = accountIdForUser('550e8400-e29b-41d4-a716-446655440000');
      final second = accountIdForUser('550e8400-e29b-41d4-a716-446655440000');

      expect(first, second);
      expect(first.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(first), isTrue);
    });

    test('produces distinct ids for different users and never leaks raw user ids', () {
      const userA = 'alice@example.com';
      const userB = 'bob@example.com';

      final idA = accountIdForUser(userA);
      final idB = accountIdForUser(userB);

      expect(idA, isNot(idB));
      expect(idA, isNot(contains('alice')));
      expect(idB, isNot(contains('bob')));
    });
  });
}
