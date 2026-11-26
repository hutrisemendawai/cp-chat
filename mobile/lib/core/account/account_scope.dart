import 'dart:async';

/// Lifetime token for an active authenticated account session.
///
/// Every user-bound provider watches `accountScopeProvider`. Async continuations
/// in `ChatSocket`, `E2eeManager`, and `ChatDao` capture the scope (or its
/// [epoch]) and drop work whenever [isOpen] becomes `false`, preventing late
/// callbacks from a signing-out session from touching a newly opened account.
class AccountScope {
  AccountScope({
    required this.accountId,
    required this.userId,
    required this.epoch,
  });

  final String accountId;
  final String userId;
  final int epoch;

  bool _open = true;
  final Completer<void> _closed = Completer<void>();

  bool get isOpen => _open;

  Future<void> get onClosed => _closed.future;

  /// Marks this scope closed immediately so any in-flight async work fails
  /// closed before teardown finishes. Idempotent.
  void beginClose() {
    if (!_open) return;
    _open = false;
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  bool operator ==(Object other) =>
      other is AccountScope &&
      other.accountId == accountId &&
      other.userId == userId &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(accountId, userId, epoch);
}

/// Serialises SQLite open/close/delete operations per file path so a rapid
/// `A -> logout -> A` switch always awaits A's previous `db.close()` before
/// reopening A's file, while `A -> logout -> B` uses distinct files with zero
/// cross-account contention.
class DbGate {
  final Map<String, Future<void>> _tails = {};

  /// Runs [action] exclusively for [key] (typically the canonical DB file path).
  Future<T> run<T>(String key, Future<T> Function() action) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (_) {});
    _tails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[key], tail)) {
          _tails.remove(key);
        }
      }),
    );
    return result;
  }

  /// Waits for any currently queued operation on [key] to settle.
  Future<void> waitFor(String key) => _tails[key] ?? Future<void>.value();
}
