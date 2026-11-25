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
    this.loadingMore = false,
    this.hasMore = false,
    this.nextOffset = 0,
    this.error,
  });

  final String query;
  final List<User> results;

  /// A first page is in flight (results are not yet shown).
  final bool loading;

  /// An additional page is in flight (results are already shown).
  final bool loadingMore;
  final bool hasMore;

  /// Offset for the next page.
  final int nextOffset;
  final String? error;

  /// A non-empty query means the friends list is replaced by search results.
  bool get isSearching => query.trim().isNotEmpty;

  /// Whether the query is long enough to hit the network (min 3 characters).
  bool get isQueryLongEnough =>
      query.trim().length >= PeopleController.minQueryLength;

  PeopleState copyWith({
    String? query,
    List<User>? results,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? nextOffset,
    String? error,
    bool clearError = false,
  }) {
    return PeopleState(
      query: query ?? this.query,
      results: results ?? this.results,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      hasMore: hasMore ?? this.hasMore,
      nextOffset: nextOffset ?? this.nextOffset,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Debounced, paginated directory search for the People screen.
///
/// A query shorter than [minQueryLength] never triggers a network call. Results
/// are requested 10 at a time; [loadMore] appends the next page. A stale
/// response is discarded whenever the query changes mid-flight.
class PeopleController extends Notifier<PeopleState> {
  static const debounce = Duration(milliseconds: 350);
  static const minQueryLength = 3;
  static const pageSize = 10;

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
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      clear();
      return;
    }
    if (trimmed.length < minQueryLength) {
      // Too short to search: drop any in-flight request and show the hint.
      _requestToken += 1;
      state = PeopleState(query: value);
      return;
    }
    state = PeopleState(query: value, loading: true);
    _debounce = Timer(debounce, () => unawaited(_search(trimmed)));
  }

  void clear() {
    _debounce?.cancel();
    _requestToken += 1;
    state = const PeopleState();
  }

  /// Loads the next page and appends it to the current results.
  void loadMore() {
    final trimmed = state.query.trim();
    if (!state.hasMore ||
        state.loading ||
        state.loadingMore ||
        trimmed.length < minQueryLength) {
      return;
    }
    unawaited(_search(trimmed, append: true));
  }

  Future<void> _search(String query, {bool append = false}) async {
    final token = ++_requestToken;
    final offset = append ? state.nextOffset : 0;
    state = state.copyWith(loading: !append, loadingMore: append, clearError: true);
    try {
      final page = await ref
          .read(apiClientProvider)
          .searchUsers(query, limit: pageSize, offset: offset);
      if (token != _requestToken) return;
      final selfId = ref.read(currentUserProvider)?.id;
      final merged = append ? [...state.results] : <User>[];
      final seen = merged.map((user) => user.id).toSet();
      for (final user in page.items) {
        if (user.id == selfId) continue;
        if (seen.add(user.id)) merged.add(user);
      }
      state = PeopleState(
        query: state.query,
        results: merged,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset ?? offset + page.items.length,
      );
    } on ApiException catch (error) {
      if (token != _requestToken) return;
      state = state.copyWith(loading: false, loadingMore: false, error: error.message);
    } catch (_) {
      if (token != _requestToken) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        error: 'Search failed. Check your connection.',
      );
    }
  }
}

final peopleControllerProvider =
    NotifierProvider<PeopleController, PeopleState>(PeopleController.new);
