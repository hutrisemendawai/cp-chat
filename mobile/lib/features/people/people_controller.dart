import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// The caller's friends, sorted so visible presence (online, idle, dnd) floats
/// above offline friends, then alphabetically within each band.
final friendsProvider = FutureProvider.autoDispose<List<User>>((ref) async {
  final users = await ref.watch(apiClientProvider).friends();
  return sortByPresence(users);
});

/// Live directory search for a trimmed query. An empty query resolves to no
/// results so the People screen shows the friends list instead.
final userSearchProvider =
    FutureProvider.autoDispose.family<List<User>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final selfId = ref.watch(currentUserProvider)?.id;
  final users = await ref.watch(apiClientProvider).searchUsers(trimmed);
  return [
    for (final user in users)
      if (user.id != selfId) user,
  ];
});

/// Fresh details for a single user, used by the profile screen.
final userProfileProvider =
    FutureProvider.autoDispose.family<User, String>((ref, userId) async {
  return ref.watch(apiClientProvider).user(userId);
});

/// Online/idle/dnd first, offline last, then by name.
List<User> sortByPresence(List<User> users) {
  final sorted = [...users];
  sorted.sort((a, b) {
    final rank = _presenceRank(a).compareTo(_presenceRank(b));
    if (rank != 0) return rank;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return sorted;
}

int _presenceRank(User user) {
  switch (user.effectiveStatus) {
    case 'online':
      return 0;
    case 'idle':
      return 1;
    case 'dnd':
      return 2;
    default:
      return 3;
  }
}

@immutable
class PeopleState {
  const PeopleState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.error,
  });

  final String query;
  final List<User> results;
  final bool loading;
  final String? error;

  bool get isSearching => query.trim().isNotEmpty;

  PeopleState copyWith({
    String? query,
    List<User>? results,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PeopleState(
      query: query ?? this.query,
      results: results ?? this.results,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Debounced directory search plus friend toggles for the People screen.
class PeopleController extends Notifier<PeopleState> {
  static const debounce = Duration(milliseconds: 300);

  Timer? _debounce;
  int _requestToken = 0;

  @override
  PeopleState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const PeopleState();
  }

  /// Called on every keystroke: shows the query immediately and searches after
  /// the debounce window. Clearing the text returns to the friends list.
  void updateQuery(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      clear();
      return;
    }
    state = state.copyWith(query: value, loading: true, clearError: true);
    _debounce = Timer(debounce, () => unawaited(_search(value)));
  }

  void clear() {
    _debounce?.cancel();
    _requestToken += 1;
    state = const PeopleState();
  }

  Future<void> _search(String value) async {
    final token = ++_requestToken;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final selfId = ref.read(currentUserProvider)?.id;
      final users = (await ref.read(apiClientProvider).searchUsers(value.trim()))
          .where((user) => user.id != selfId)
          .toList();
      if (token != _requestToken) return;
      state = state.copyWith(results: users, loading: false);
    } on ApiException catch (error) {
      if (token != _requestToken) return;
      state = state.copyWith(loading: false, error: error.message);
    } catch (_) {
      if (token != _requestToken) return;
      state = state.copyWith(
        loading: false,
        error: 'Search failed. Check your connection.',
      );
    }
  }

  /// Adds or removes a friend, flipping the row immediately and reverting if the
  /// request fails. Returns an error message, or `null` on success.
  Future<String?> toggleFriend(User user) async {
    final target = !user.isFriend;
    _setFriendFlag(user.id, target);
    try {
      final api = ref.read(apiClientProvider);
      if (target) {
        await api.addFriend(userId: user.id);
      } else {
        await api.removeFriend(user.id);
      }
      ref.invalidate(friendsProvider);
      return null;
    } catch (error) {
      _setFriendFlag(user.id, !target);
      return error is ApiException ? error.message : 'Could not update friend';
    }
  }

  /// Adds a friend by email, phone or exact name.
  Future<String?> addFriendByIdentifier(String identifier) async {
    try {
      await ref.read(apiClientProvider).addFriend(identifier: identifier);
      ref.invalidate(friendsProvider);
      return null;
    } catch (error) {
      return error is ApiException ? error.message : 'Could not add friend';
    }
  }

  void _setFriendFlag(String userId, bool isFriend) {
    state = state.copyWith(
      results: [
        for (final user in state.results)
          user.id == userId ? user.copyWith(isFriend: isFriend) : user,
      ],
    );
  }
}

final peopleControllerProvider =
    NotifierProvider<PeopleController, PeopleState>(PeopleController.new);
