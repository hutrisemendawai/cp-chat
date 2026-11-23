import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/app_widgets.dart';

/// In-chat search, styled after the Stitch "Search this chat" sheet: a prominent
/// rounded field pinned at the top, with a centred empty state below it.
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
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.lg,
          ),
          child: Column(
            children: [
              SearchField(
                controller: _controller,
                hintText: 'Search this chat',
                autofocus: true,
                onSubmitted: (_) => _run(),
                onClear: () {
                  _controller.clear();
                  _run();
                },
              ),
              if (_busy) ...[
                const SizedBox(height: AppSpacing.md),
                const LinearProgressIndicator(),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
              Expanded(
                child: _results.isEmpty
                    ? const EmptyState(
                        icon: Icons.search,
                        title: 'No matches',
                        message: 'Search this conversation for text.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                        itemCount: _results.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: scheme.outlineVariant,
                        ),
                        itemBuilder: (context, index) {
                          final message = _results[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              message.type == 'text' ? message.content : 'Attachment',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                            subtitle: Text(
                              '#${message.seq}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontFamily: AppTypography.mono,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
