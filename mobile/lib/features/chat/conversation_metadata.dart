import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';

/// Reads a single conversation's metadata from the server and caches the peer
/// name locally, so the chat header and list can render it offline.
final conversationMetadataProvider =
    FutureProvider.family<Conversation?, String>((ref, conversationId) async {
  final api = ref.watch(apiClientProvider);
  final dao = ref.watch(chatDaoProvider);
  final selfId = ref.watch(currentUserProvider)?.id;

  try {
    final conversation = await api.conversation(conversationId);
    await dao.upsertConversation(conversation, selfId: selfId);
    return conversation;
  } on ApiException catch (error) {
    if (error.statusCode == 401) rethrow;
    // Offline: fall back to whatever was last cached.
    return null;
  }
});
