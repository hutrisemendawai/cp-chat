import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';

/// Group lifecycle operations (create, rename, avatar, membership). Kept
/// separate from [ChatController] so the conversation screen stays about
/// messaging while the info screen owns administration.
class GroupController {
  GroupController(this._ref);

  final Ref _ref;

  ApiClient get _api => _ref.read(apiClientProvider);

  Future<Conversation> create({
    required String name,
    required List<String> memberIds,
  }) async {
    final conversation = await _api.createGroupConversation(
      name: name,
      memberIds: memberIds,
    );
    await _ref.read(chatDaoProvider).upsertConversation(
          conversation,
          selfId: _ref.read(currentUserProvider)?.id,
        );
    return conversation;
  }

  Future<Conversation> rename(String conversationId, String name) async {
    final conversation = await _api.updateGroup(conversationId, name: name);
    await _cache(conversation);
    return conversation;
  }

  Future<void> setAvatar(String conversationId, String? objectKey) async {
    final conversation = await _api.updateGroup(
      conversationId,
      avatarKey: objectKey,
      clearAvatar: objectKey == null,
    );
    await _cache(conversation);
  }

  Future<Conversation> addMembers(String conversationId, List<String> userIds) async {
    await _api.addGroupMembers(conversationId, userIds);
    final conversation = await _api.conversation(conversationId);
    await _cache(conversation);
    return conversation;
  }

  /// Removes a member, or leaves when [userId] is the caller.
  Future<void> removeMember(String conversationId, String userId) async {
    await _api.removeGroupMember(conversationId, userId);

    final selfId = _ref.read(currentUserProvider)?.id;
    if (userId == selfId) {
      // The local mirror must drop the conversation so it leaves the list.
      await _ref.read(chatDaoProvider).deleteConversation(conversationId);
      return;
    }
    final conversation = await _api.conversation(conversationId);
    await _cache(conversation);
  }

  Future<void> _cache(Conversation conversation) async {
    await _ref.read(chatDaoProvider).upsertConversation(
          conversation,
          selfId: _ref.read(currentUserProvider)?.id,
        );
  }
}

final groupControllerProvider = Provider<GroupController>(GroupController.new);
