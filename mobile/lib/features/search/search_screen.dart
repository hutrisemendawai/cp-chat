import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

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
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (value) => _run(value.trim()),
          decoration: const InputDecoration(
            hintText: 'Search messages',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                _run('');
              },
            ),
        ],
      ),
      body: _body(theme),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)));
    }
    if (_busy && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_query.isEmpty) {
      return Center(
        child: Text('Search across all your chats', style: theme.textTheme.bodyLarge),
      );
    }
    if (_results.isEmpty) {
      return Center(child: Text('No messages match "$_query"', style: theme.textTheme.bodyLarge));
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final hit = _results[index];
        return ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text(
            hit.message.type == 'text' ? hit.message.content : 'Attachment',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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
