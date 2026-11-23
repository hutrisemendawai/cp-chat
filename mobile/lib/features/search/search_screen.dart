import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_widgets.dart';

/// Global message search across every conversation the user belongs to.
///
/// Results carry their conversation id, so tapping a hit opens the right chat.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SearchHit> _results = const [];
  bool _busy = false;
  String? _error;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value.trim()));
  }

  Future<void> _run(String query) async {
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
        _error = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _query = query;
    });

    try {
      final hits = await ref.read(apiClientProvider).search(query);
      if (!mounted || query != _query) return;
      setState(() => _results = hits);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Search failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.md),
          child: SearchField(
            controller: _controller,
            hintText: 'Search messages',
            autofocus: true,
            onChanged: _onChanged,
            onSubmitted: (value) => _run(value.trim()),
            onClear: () {
              _controller.clear();
              _run('');
            },
          ),
        ),
      ),
      body: _body(theme),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Search failed',
        message: _error!,
      );
    }
    if (_busy && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_query.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        title: 'Search your chats',
        message: 'Find any message across your conversations.',
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        message: 'Nothing matches "$_query".',
      );
    }

    final scheme = theme.colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.section),
      itemCount: _results.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: AppSpacing.lg + 40 + AppSpacing.md,
        endIndent: AppSpacing.lg,
        color: scheme.outlineVariant,
      ),
      itemBuilder: (context, index) {
        final hit = _results[index];
        return ListTile(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: scheme.secondaryContainer,
            child: Icon(
              Icons.chat_bubble_outline,
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
          ),
          title: Text(
            hit.message.type == 'text' ? hit.message.content : 'Attachment',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          subtitle: Text(_relativeTime(hit.message.createdAt)),
          onTap: () => context.push('/conversations/${hit.message.conversationId}'),
        );
      },
    );
  }

  String _relativeTime(DateTime time) {
    final local = time.toLocal();
    final difference = DateTime.now().difference(local);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return '${local.day}/${local.month}';
  }
}
