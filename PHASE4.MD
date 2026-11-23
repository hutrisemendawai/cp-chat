You are executing Phase 4 of PLAN.MD for CP Chat. Implement user search by Name or Email and a Friends/Contacts system on the backend, and replace every UUID input across the Flutter mobile app with live Name/Email search and friend pickers, then verify and push to git main.

Tasks:
1. Database Migration (`backend/migrations/000007_contacts_and_user_search.up.sql` & `.down.sql`):
   - Create `user_friends` table:
     - `user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`
     - `friend_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`
     - `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
     - `PRIMARY KEY (user_id, friend_id)`
     - `CHECK (user_id <> friend_id)`
   - Add indexes for fast lookup and case-insensitive search:
     - `CREATE INDEX user_friends_user_id_idx ON user_friends (user_id);`
     - `CREATE INDEX users_lower_name_idx ON users (lower(name));`
     - `CREATE INDEX users_lower_phone_or_email_idx ON users (lower(phone_or_email));`
   - Write the corresponding `.down.sql`.

2. Backend User Search & Friends APIs (`backend/src/domain/users.ts`, `backend/src/domain/friends.ts`, `backend/src/http/user-routes.ts`, `backend/src/http/friend-routes.ts`, `backend/src/http/server.ts`):
   - `GET /api/v1/users/search?q=<query>&limit=20`:
     - Requires auth. Trims `q` (min 1 char, max 100 chars; limit 1..50 default 20).
     - Searches `users` where `id <> request.userId` and (`lower(name) LIKE '%' || lower($q) || '%'` OR `lower(phone_or_email) LIKE '%' || lower($q) || '%'`).
     - Important: Primary `name` and `phone_or_email` are the searchable identity fields (nickname is returned in results for display as `Name (nickname)`). Order exact email/name prefix matches first, then alphabetical by `name`.
     - Returns `{ users: [...] }` where each item includes `id`, `name`, `nickname`, `phone_or_email`, `avatar_url`, `custom_status`, `effective_status`, `online`, `last_seen_at`, and `is_friend: boolean`.
   - Friends endpoints (`registerFriendRoutes`):
     - `GET /api/v1/friends`: Lists the authenticated user's friends with live presence (`effective_status`, `online`, `last_seen_at`), `name`, `nickname`, `phone_or_email`, `avatar_url`, `custom_status`, ordered by online first then `name`.
     - `POST /api/v1/friends`: Accepts `{ identifier: string }` (email/phone or exact name) OR `{ user_id: string }` (when clicked from search results). Resolves the target user, prevents self-add, inserts idempotently into `user_friends`, and returns `201` with the added friend's public profile.
     - `DELETE /api/v1/friends/:friendId`: Removes a friend (`204`).
   - Update `GET /api/v1/users/:id` to also return `is_friend: boolean` relative to the authenticated caller.
   - Update `PresenceService.sharedPeerIds()` so presence updates are also broadcast to users who have `userId` in their `user_friends` list (not only existing conversation members), so friends see live Discord status changes in the People/Friends list.

3. Flutter API Client & Reusable User Search Picker (`mobile/lib/core/network/api_client.dart`, `mobile/lib/shared/widgets/user_search_picker.dart`):
   - Add `ApiClient` methods:
     - `searchUsers(String query, {int limit = 20})` -> `Future<List<User>>`
     - `friends()` -> `Future<List<User>>`
     - `addFriend({String? userId, String? identifier})` -> `Future<User>`
     - `removeFriend(String friendId)` -> `Future<void>`
   - Extend `User` model with `isFriend` (`bool`, default `false`).
   - Build a debounced (300ms) reusable `UserSearchPicker` widget/sheet that searches by **Name or Email** (never UUID), displays `UserAvatarWithStatus`, `user.displayName` (`Name (nickname)`), and `user.phoneOrEmail`, and lets the user pick one or multiple users.

4. Eliminate ALL UUID Prompts in Existing Flutter Screens:
   - `mobile/lib/features/conversations/conversations_screen.dart`:
     - Replace `_NewChatSheet`'s UUID text field with live search by **Name or Email** (plus quick access to existing Friends list). Tapping a user starts/opens a direct chat immediately; tapping their info/avatar opens their profile.
   - `mobile/lib/features/groups/create_group_screen.dart`:
     - Replace "Add member by user id" with live **Name or Email** search suggestions + friend quick-select chips. Display selected members with `Name (nickname)` and email instead of raw UUIDs.
   - `mobile/lib/features/groups/group_info_screen.dart`:
     - Replace the "Paste the user id to add" dialog with the Name/Email search modal picker. Display group members with `Name (nickname)`, avatar, and status dot instead of raw UUIDs.

5. Tests & Verification:
   - Add backend Vitest tests (`backend/test/friends-and-search.test.ts`) testing `GET /api/v1/users/search` (by name substring, by email, excluding self, `is_friend` flag), `POST/GET/DELETE /api/v1/friends`, and presence fan-out to friends.
   - Run `cd backend && npm run typecheck && npm test` and `cd mobile && flutter analyze && flutter test`.
   - Update `docs/api-spec.yaml`.
   - Commit all changes cleanly and push to `git main`.
