You are executing Phase 3 of PLAN.MD for CP Chat. Implement the complete User Profile System (avatar photo, nickname displayed as "Name (nickname)", and Discord-style presence status) across PostgreSQL, backend REST/WebSocket, and Flutter mobile, then verify and push to git main.

Tasks:
1. Database Migration (`backend/migrations/000006_user_profiles.up.sql` & `.down.sql`):
   - Alter `users` table to add:
     - `nickname VARCHAR(60)` (nullable)
     - `status VARCHAR(20) NOT NULL DEFAULT 'online' CHECK (status IN ('online', 'idle', 'dnd', 'invisible'))`
     - `custom_status VARCHAR(120)` (nullable)
     - `bio TEXT` (nullable)
   - Write the corresponding `.down.sql` migration cleanly.

2. Backend User Profile & Discord Presence Engine:
   - Update `backend/src/domain/users.ts`:
     - Extend `UserRow` and `PublicUser` with `nickname: string | null`, `status: UserStatus` (`'online' | 'idle' | 'dnd' | 'invisible'`), `custom_status: string | null`, `bio: string | null`, and `effective_status?: EffectiveStatus` (`'online' | 'idle' | 'dnd' | 'offline'`).
     - Note on privacy: for other users, never leak `'invisible'` — map `'invisible'` to `'offline'` in public responses while returning the user's real preference (`status`) on `/api/v1/users/me`.
     - Add `updateProfile(userId, patch)` supporting `name`, `nickname` (nullable/trim), `avatar_url` (nullable), `status`, `custom_status` (nullable), and `bio` (nullable).
   - Update `backend/src/domain/conversations.ts`:
     - Include `nickname`, `avatar_url`, `custom_status` in `ConversationSummary.members[].user` queries so direct chats and groups display `Name (nickname)` and user avatars automatically.
   - Update `backend/src/domain/presence.ts` and `backend/src/gateway/chat-gateway.ts`:
     - Extend `PresenceSnapshot` with `status: 'online' | 'idle' | 'dnd' | 'offline'` and `custom_status: string | null` (keep `online: boolean` for backward compatibility where `online = status !== 'offline'`).
     - Compute effective visible status: if user has no active Redis presence key OR `users.status === 'invisible'`, visible status is `'offline'` (`online: false`). Otherwise visible status is `users.status` (`'online' | 'idle' | 'dnd'`, `online: true`).
     - When a user updates their status/custom_status via REST or WS, broadcast an updated `presence` frame `{ type: 'presence', user_id, online, status, custom_status, last_seen_at }` to all shared peers via the broker.
     - In `ChatGateway.maybeNotify()`, skip FCM push notifications when the recipient's `users.status === 'dnd'`.
     - When a user whose `users.status === 'invisible'` connects/disconnects, do NOT broadcast `online: true` to peers.
   - Update `backend/src/http/user-routes.ts`:
     - `PATCH /api/v1/users/me`: Update `name`, `nickname`, `avatar_url`, `status`, `custom_status`, `bio` with Zod validation. If `status` or `custom_status` changed, trigger a presence broadcast to shared peers via `ctx.broker`.
     - `GET /api/v1/users/me`: Return full own profile including preferred `status` and `effective_status`.
     - `GET /api/v1/users/:id`: Return public user profile including `nickname`, `avatar_url`, `bio`, `custom_status`, `effective_status`, `online`, `last_seen_at`, and `phone_or_email` (so internal app users can identify contacts by email).
   - Fix Avatar Read ACL in `backend/src/http/media-routes.ts`:
     - In `GET /api/v1/media/*`, allow any authenticated user to read a media object if it is referenced as `users.avatar_url` (or `conversations.avatar_url` for a conversation they belong to), in addition to the existing owner / shared-conversation check. This ensures profile photos load even before starting a chat.

3. Flutter Models, Drift Cache & Shared Widgets:
   - Update `mobile/lib/core/models/models.dart`:
     - Extend `User` with `nickname`, `status`, `effectiveStatus`, `customStatus`, `bio`, `lastSeenAt`.
     - Add helper `String get displayName => (nickname != null && nickname!.trim().isNotEmpty) ? '$name (${nickname!.trim()})' : name;`.
     - Extend `Presence` with `status` (`'online' | 'idle' | 'dnd' | 'offline'`) and `customStatus`.
   - Update `mobile/lib/core/database/app_database.dart` (bump `schemaVersion` to `5` with clean migration + update `app_database.g.dart` via `dart run build_runner build --delete-conflicting-outputs` or hand-verified update):
     - Add `peerId`, `peerNickname`, `peerAvatarUrl` to `LocalConversations` so the chat list renders peer avatars, Discord status dots, and `Name (nickname)` directly from the local cache.
   - Update `mobile/lib/core/network/api_client.dart`:
     - Add `updateProfile({ name, nickname, avatarUrl, clearAvatar, status, customStatus, bio })` calling `PATCH /api/v1/users/me`.
   - Create reusable widgets (`mobile/lib/shared/widgets/user_avatar.dart`, `mobile/lib/shared/widgets/status_badge.dart`):
     - `UserAvatarWithStatus`: Renders `MediaAvatar` (or initials fallback) with a bottom-right Discord-style status dot:
       - `online`: solid green circle (`#23A55A`)
       - `idle`: amber/yellow circle with crescent notch (`#F0B232`)
       - `dnd`: red circle with horizontal dash (`#F23F43`)
       - `offline`/`invisible`: grey ring/hollow circle (`#80848E`)
   - Update `PresenceNotifier` and `formatPresence()` in `mobile/lib/features/presence/presence_controller.dart` to handle `online`, `idle`, `dnd`, `offline`, and `customStatus` labels.
   - Update `ConversationsScreen` and `ChatScreen` headers to show `Name (nickname)`, peer avatar, and Discord status indicator.

4. Flutter My Profile & Edit Profile Screen (`mobile/lib/features/profile/my_profile_screen.dart`):
   - Allow viewing and editing:
     - Profile Photo (tap avatar -> pick from gallery/camera -> upload via `MediaService.uploadImage` -> save `avatar_url`).
     - Primary Name (display + optional edit) and Nickname (with live preview showing `Name (nickname)`).
     - Discord-style Status selector (`Online`, `Idle`, `Do Not Disturb`, `Invisible`) with color-coded icons and descriptions.
     - Custom Status text field (max 120 chars, with quick clear button) and Bio.
     - Sign Out button.
   - Updating profile refreshes `authControllerProvider` user state immediately.
   - Add `/profile` route in `mobile/lib/main.dart` and an accessible profile icon in `ConversationsScreen` AppBar (which Phase 5 will expand into full bottom navigation).

5. Tests & Verification:
   - Add backend Vitest tests (`backend/test/profile.test.ts`) covering `PATCH /api/v1/users/me`, Discord status transitions (`online`/`idle`/`dnd`/`invisible`), invisible privacy masking, presence broadcast frames, DND notification suppression, and cross-user avatar access in `GET /api/v1/media/*`.
   - Update Flutter model/presence tests (`mobile/test/models_test.dart`, `mobile/test/presence_and_search_test.dart`).
   - Run `cd backend && npm run typecheck && npm test` and `cd mobile && flutter analyze && flutter test`.
   - Update `docs/api-spec.yaml` and `docs/ws-protocol.md`.
   - Commit all changes cleanly and push to `git main`.
