import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// In-chat search: narrows results to the open conversation server-side.
class ChatSearchSheet extends ConsumerStatefulWidget {
  const ChatSearchSheet({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatSearchSheet> createState() => _ChatSearchSheetState();
}

class _ChatSearchSheetState extends ConsumerState<ChatSearchSheet> {
  final _controller = TextEditingController();
  List<Message> _results = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(apiClientProvider)
          .searchConversation(widget.conversationId, query);
      if (mounted) setState(() => _results = page.messages);
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

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _run(),
                decoration: InputDecoration(
                  hintText: 'Search this chat',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _busy ? null : _run,
                  ),
                ),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            Expanded(
              child: _results.isEmpty
                  ? Center(child: Text('No matches', style: theme.textTheme.bodyLarge))
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final message = _results[index];
                        return ListTile(
                          title: Text(
                            message.type == 'text' ? message.content : 'Attachment',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('#${message.seq}'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
