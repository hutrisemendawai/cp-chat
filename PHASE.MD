You are executing Phase 5 of PLAN.MD for CP Chat. Build the mobile People/Directory screen, the User Profile detail screen with a direct Chat CTA button, and clean top-level navigation across Chats, People, and Profile, then verify and push to git main.

Tasks:
1. Top-Level Navigation Shell (`mobile/lib/main.dart`, `mobile/lib/features/home/home_shell.dart`):
   - Wrap the main authenticated experience in a clean Material 3 `NavigationBar` (Bottom Navigation) using GoRouter `StatefulShellRoute.indexedStack` (or clean shell) with 3 tabs:
     1. **Chats** (`/conversations`) — Existing conversation list.
     2. **People** (`/people`) — User search directory & Friends list.
     3. **Profile** (`/profile`) — Current user's own profile, avatar, nickname, Discord status switcher, and logout.
   - Add standalone pushed routes (hiding bottom nav):
     - `/users/:id` -> `UserProfileScreen(userId: id)`
     - `/conversations/:id` -> `ChatScreen`
     - `/conversations/new-group` -> `CreateGroupScreen`
     - `/conversations/:id/info` -> `GroupInfoScreen`
     - `/search` -> `SearchScreen` (message search)

2. People / Find Users Screen (`mobile/lib/features/people/people_screen.dart`, `mobile/lib/features/people/people_controller.dart`):
   - Top search bar: "Search users by name or email..." with 300ms debounce and clear button.
   - When search query is empty:
     - Display **Friends** list (pull-to-refresh) grouped or sorted with online/idle/dnd friends first, plus an "Add Friend by Email / Name" action button if empty.
   - When search query is non-empty:
     - Display live **Directory Search Results** from `GET /api/v1/users/search?q=...`.
   - Each user list tile displays:
     - `UserAvatarWithStatus` (live Discord status dot via `presenceProvider(user.id)` seeded from REST response).
     - Title: `user.displayName` (`Name (nickname)` when nickname is set, else `Name`).
     - Subtitle: `customStatus` (if present) or `phoneOrEmail`.
     - Tap row -> navigates to `/users/${user.id}` (`UserProfileScreen`).
     - Trailing quick-action icons:
       - Direct **Chat** icon button (`Icons.chat_bubble_outline`) -> creates/opens 1:1 conversation (`POST /api/v1/conversations`) and immediately pushes `/conversations/${conversation.id}`.
       - **Add Friend** / **Friends checkmark** toggle button (in search results).

3. User Profile Screen (`mobile/lib/features/profile/user_profile_screen.dart`):
   - Fetches latest user details via `GET /api/v1/users/:id` and subscribes to `presenceProvider(userId)` for real-time Discord status updates.
   - Clean Discord-inspired profile card layout:
     - Header banner + large circular `UserAvatarWithStatus` (72–88dp, tap avatar to view full-screen image preview).
     - Display title: primary `Name`, with subtle pill/subtitle `(nickname)` rendered clearly as `Name (nickname)`.
     - Discord Status row: colored status dot + readable label (`Online`, `Idle`, `Do Not Disturb`, or `Offline` + `Last seen ...`) + `customStatus` bubble if set.
     - Contact info (`phone_or_email`) and `Bio` card (if non-empty).
     - Action bar with two prominent buttons:
       1. Primary FilledButton: **"Message"** (`Icons.chat`) — calls `createDirectConversation(user.id)`, upserts into `ChatDao`, and navigates straight to `/conversations/${conversation.id}`.
       2. Outlined/Tonal Button: **"Add Friend"** / **"Remove Friend"** — toggles friendship via `POST /api/v1/friends` or `DELETE /api/v1/friends/:id` with optimistic feedback and refreshes `friendsProvider`.
   - If the profile opened is the current user themselves, show an "Edit Profile" button redirecting to `/profile` instead of "Message" / "Add Friend".

4. Cross-Screen Profile Linking:
   - In `ChatScreen` (`mobile/lib/features/chat/chat_screen.dart`): for 1:1 direct chats, make the AppBar title/avatar tappable to push `/users/$peerId` so the user can view the peer's full profile at any time.
   - In `GroupInfoScreen` (`mobile/lib/features/groups/group_info_screen.dart`): tapping a group member row opens `/users/${member.user.id}` (while keeping admin remove action in trailing menu/button).

5. Tests & Verification:
   - Add Flutter widget tests (`mobile/test/people_and_profile_test.dart`) covering:
     - Rendering `Name (nickname)` vs `Name` without nickname.
     - Searching users by name/email on `PeopleScreen`.
     - Opening `UserProfileScreen` and tapping the **Message** button to navigate to the direct conversation.
   - Run `cd mobile && flutter analyze && flutter test`.
   - Commit all changes cleanly and push to `git main`.
