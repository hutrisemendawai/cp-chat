import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// Opens (creating if needed) the 1:1 conversation with [user] and shows it.
Future<void> openDirectChat(BuildContext context, WidgetRef ref, User user) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final conversation =
        await ref.read(apiClientProvider).createDirectConversation(user.id);
    await ref.read(chatDaoProvider).upsertConversation(
          conversation,
          selfId: ref.read(currentUserProvider)?.id,
        );
    if (!context.mounted) return;
    context.push('/conversations/${conversation.id}');
  } on ApiException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not open chat. Check your connection.')),
    );
  }
}
