# CP Chat — Bugfix & Notification Expansion Plan (`BUGFIX_PLAN.md`)

## How to Use This Plan with an Agentic AI
Instruct your coding agent with:
> `Read AGENTS.MD and BUGFIX_PLAN.md. Start Phase <N>, complete every requirement and acceptance check, commit cleanly, and push to git main.`

### Global Rules for Every Phase
1. **Follow repository conventions** in `AGENTS.MD` (TypeScript strict mode, Fastify + Zod, PostgreSQL numbered migrations, Riverpod + Drift + GoRouter in Flutter, Android mobile target only).
2. **Clean code:** Do not add unnecessary inline comments. Keep code self-explanatory.
3. **Never break existing contracts or tests:** Run `cd mobile && flutter analyze && flutter test` (and `cd backend && npm run typecheck && npm test` when backend files are touched) before committing.
4. **Preserve offline-first & E2EE invariants:** Never write raw E2EE ciphertext envelopes into user-visible previews or notifications.
5. **Git discipline:** Commit all changes for each phase with a conventional commit message (e.g., `fix(mobile): phase 1 - preserve decrypted previews in direct chat list`) and push to `main` only after all verification checks pass.

---

## Phase Overview

| Phase | Focus | Primary Scope |
| :--- | :--- | :--- |
| **Phase 1** | Fix "Encrypted message" Preview in Personal Chat List | `ChatDao` preview resolution & preservation, optimistic outgoing previews, sync/decryption order |
| **Phase 2** | Fix Group Chat Header Showing Member Name Instead of Group Name | `Conversation.otherMember`, `ChatScreen` header title/subtitle & tap action |
| **Phase 3** | Fix Unresponsive Profile Logout Button | Fault-tolerant non-blocking `AuthController.logout()`, `ChatSocket.disconnect()` timeouts, `MyProfileScreen` layout & UX |
| **Phase 4** | Fix Chat Auto-Scroll When Keyboard Opens | Keyboard-aware `ChatScreen` list anchoring (`reverse: true` or inset tracking), `AndroidManifest.xml` soft input mode |
| **Phase 5** | Add Real-Time Incoming Message Notifications | `flutter_local_notifications` Android channel, foreground/background WS + FCM triggers, DND/active-chat suppression, tap-to-open routing |
| **Phase 6** | End-to-End Regression Verification & Android Device Smoke Check | Full automated test suite, widget tests for all 5 items, physical Android LAN APK checklist |

---

## Phase 1: Fix "Encrypted message" Preview on Personal Chat List

### Diagnosed Root Cause
Direct (1:1) chats are end-to-end encrypted on the server, while group chats are stored in plaintext—which is why this bug only affects personal chats.
1. When `/api/v1/conversations` is fetched (during `ChatSocket.syncAll()`, `ConversationsScreen._refresh()`, or `conversationMetadataProvider`), the server returns each direct conversation's `lastMessage.content` as the raw E2EE ciphertext envelope.
2. In `mobile/lib/core/database/chat_dao.dart`:
   - `upsertConversations()` (lines 81–105) uses `InsertMode.insertOrReplace` and unconditionally writes `lastMessagePreview: Value(_preview(conversation.lastMessage))`.
   - `upsertConversation()` (lines 107–137) likewise unconditionally overwrites `lastMessagePreview: Value(_preview(conversation.lastMessage))`.
   - `_textPreview(content)` (lines 170–171) returns `'Encrypted message'` whenever `isEncryptedContent(content)` is `true`, clobbering any decrypted plaintext preview already known locally.
3. `enqueueOutgoing()` (lines 190–222) inserts the optimistic message into `local_messages` and `outbox_entries` without updating `local_conversations.lastMessagePreview` or `updatedAt`.
4. `_bumpConversationCursor()` (lines 422–442) unconditionally overwrites `lastMessagePreview` even if the incoming row is older than `existing.lastSeq` or contains unreadable ciphertext while a readable preview already exists.

### Tasks
1. **Preserve and Resolve Readable Previews in `mobile/lib/core/database/chat_dao.dart`:**
   - Add a helper `_resolvePreview(Conversation conversation, LocalConversation? existing)` (or async equivalent querying `local_messages`):
     - If `conversation.lastMessage` is `null`, return `null`.
     - If `conversation.lastMessage!.type != 'text'`, return `'Sent an attachment'` (or `'Sent an image'` / `'Sent a file'` consistently).
     - If `!_isUnreadable(conversation.lastMessage!.content)`, return `conversation.lastMessage!.content`.
     - If the server's `lastMessage.content` **is** encrypted/unreadable:
       1. Look up the matching row in `local_messages` by `clientMsgId` (`conversation.lastMessage!.clientMsgId`). If found and readable (`!_isUnreadable(localRow.content)`), return `localRow.content`.
       2. Otherwise, check the latest local message for `conversation.id` with `seq >= conversation.lastSeq` (or matching `seq == conversation.lastMessage!.seq`). If readable, return its content.
       3. Otherwise, if `existing != null && existing.lastSeq >= conversation.lastSeq && existing.lastMessagePreview != null && existing.lastMessagePreview != 'Encrypted message' && existing.lastMessagePreview != undecryptableContent`, preserve `existing.lastMessagePreview`.
       4. Only fall back to `'Encrypted message'` when no decrypted copy exists locally yet.
   - Refactor `upsertConversations()` to run inside `db.transaction(...)` and read existing `local_conversations` / `local_messages` before upserting (using `insertOnConflictUpdate` instead of destructive `InsertMode.insertOrReplace`), applying the resolved preview.
   - Apply the same preview resolution in `upsertConversation()`.
2. **Update Optimistic Send & Cursor Bumping in `mobile/lib/core/database/chat_dao.dart`:**
   - In `enqueueOutgoing()`, also update `local_conversations` (`lastMessagePreview` using plaintext `content` and `updatedAt: createdAt`) inside the same transaction so sent personal messages immediately show plaintext on the chat list.
   - In `_bumpConversationCursor()`:
     - Only update `lastMessagePreview` if `existing == null || message.seq >= existing.lastSeq`.
     - Never overwrite an existing readable `lastMessagePreview` with `'Encrypted message'` or `undecryptableContent` when `message.seq == existing.lastSeq`.
3. **Decrypt `lastMessage` During Conversation Sync (`mobile/lib/core/network/ws_client.dart`):**
   - In `ChatSocket.syncAll()`, verify that after `upsertConversations()`, pulling missed messages for each conversation decrypts incoming direct messages via `decrypt(...)` and calls `upsertServerMessage(...)`, which updates `local_conversations.lastMessagePreview` with the decrypted plaintext.
   - If a conversation has `lastMessage != null` and `isEncryptedContent(lastMessage.content)` and no local decrypted row exists yet, ensure `syncAll()` fetches and decrypts the missing sequence range so the chat list displays plaintext without requiring the user to open the chat first.
4. **Add/Update Unit Tests (`mobile/test/chat_dao_test.dart`):**
   - Verify `upsertConversations()` and `upsertConversation()` do not overwrite a decrypted plaintext preview with `'Encrypted message'` when the server returns an encrypted `lastMessage`.
   - Verify `upsertConversations()` resolves plaintext from an already-decrypted row in `local_messages`.
   - Verify `enqueueOutgoing()` immediately sets plaintext `lastMessagePreview` for direct chats.
   - Verify group chats continue displaying plaintext previews identically.

### Acceptance Criteria
- Sending or receiving a personal (1:1) text message shows the decrypted plaintext preview on `ConversationsScreen`.
- Pulling to refresh on `ConversationsScreen` or re-opening the app keeps the plaintext preview and never reverts it to `"Encrypted message"`.
- Group chat previews remain unaffected.
- `flutter analyze` and `flutter test` pass.

---

## Phase 2: Fix Group Chat Header Displaying Member Name Instead of Group Name

### Diagnosed Root Cause
1. In `mobile/lib/core/models/models.dart` (lines 230–236), `Conversation.otherMember(String selfId)` documents `"The other participant of a direct conversation, null for groups"`, **but omits the group check** and returns the first member whose `user.id != selfId` even for group chats.
2. In `mobile/lib/features/chat/chat_screen.dart` (lines 187–196):
   - `isGroup` is evaluated **after** `peer` and `title`.
   - Because `metadata.value?.otherMember(selfId)` returns a member for group conversations, `peerLabel` is non-null.
   - Since `cached?.peerName` is `null` for groups, `title` evaluates `peerLabel ?? cached?.name ?? ...` and displays a member's name instead of the group's name.

### Tasks
1. **Fix `Conversation.otherMember` in `mobile/lib/core/models/models.dart`:**
   - Guard at the top of `otherMember(String selfId)`:
     ```dart
     if (isGroup) return null;
     ```
2. **Fix Header Title, Subtitle, and Tap Behavior in `mobile/lib/features/chat/chat_screen.dart`:**
   - Compute `isGroup` first:
     ```dart
     final isGroup = cached?.type == 'group' || metadata.value?.isGroup == true;
     ```
   - Compute `peer` only when `!isGroup`:
     ```dart
     final peer = isGroup || selfId == null ? null : metadata.value?.otherMember(selfId);
     ```
   - Compute `title` explicitly by conversation type:
     - When `isGroup`: `metadata.value?.name?.trim().isNotEmpty == true ? metadata.value!.name! : (cached?.name?.trim().isNotEmpty == true ? cached!.name! : 'Group')`.
     - When `!isGroup`: `peer?.user.displayName ?? (cached?.peerName != null ? _peerLabelFromCache(cached!) : null) ?? cached?.name ?? 'Chat'`.
   - Add a concise subtitle for group chats showing the member count (e.g., `'${metadata.value!.members.length} members'`) when metadata is loaded.
   - Update the AppBar title `InkWell.onTap`:
     - If `isGroup`: navigate to `/conversations/${widget.conversationId}/info` (consistent with the info action button).
     - If `!isGroup` and `peerUserId != null`: navigate to `/users/$peerUserId`.
3. **Verify Group Rename Propagation:**
   - Confirm that after renaming a group in `mobile/lib/features/groups/group_info_screen.dart`, both `local_conversations.name` and `conversationMetadataProvider(conversationId)` are refreshed/invalidated so returning to `ChatScreen` immediately shows the updated group name.
4. **Add Tests (`mobile/test/models_test.dart` & widget test):**
   - Assert `Conversation(type: 'group', ...).otherMember(selfId)` returns `null`.
   - Add a widget test rendering `ChatScreen` for a group conversation with multiple members and asserting the AppBar displays the group name and never a member's name.

### Acceptance Criteria
- Opening any group conversation displays the group's name in the AppBar header both offline (from Drift cache) and online (after metadata loads).
- Tapping the group header opens Group Info.
- Direct (1:1) chat headers continue showing `"Name (nickname)"` and peer presence status.
- `flutter analyze` and `flutter test` pass.

---

## Phase 3: Fix Unresponsive Logout Button on Profile Screen

### Diagnosed Root Cause
1. **Potential Blocking/Hanging Async Calls in `AuthController.logout()` (`mobile/lib/core/providers.dart:244–253`):**
   - `logout()` awaits `sessionRuntimeProvider.notifier.stop()` -> `ChatSocket.disconnect()` (`ws_client.dart:185–207`) -> `await subscription?.cancel(); await channel?.sink.close();` with **no timeout and no error handling**. On mobile networks with half-open sockets, `sink.close()` can hang indefinitely, preventing `api.logout()`, `clearAll()`, and `state = null` from ever executing.
   - `api.logout()` (`api_client.dart:201–215`) posts to `/api/v1/auth/logout` without a short timeout; if the backend is unreachable or slow, logout appears frozen.
   - Setting `state = null` triggers `SessionRuntime.build()`'s listener (`providers.dart:129–135`), which invokes `_stop()` a second time concurrently.
2. **Missing Loading State, Error Handling, and Bottom Hit-Target Clearance in `MyProfileScreen` (`mobile/lib/features/profile/my_profile_screen.dart`):**
   - `_signOut()` (lines 175–178) has no `_signingOut` state, no `try/catch`, no keyboard dismissal (`FocusScope.of(context).unfocus()`), and no visual feedback.
   - The "Sign out" `OutlinedButton.icon` sits at the very bottom of a `ListView` with only `32px` bottom padding above `HomeShell`'s `NavigationBar` and system gesture bar, making taps easy to miss or swallow by keyboard/scroll focus.
   - If `_loading` stalls or fails, no sign-out escape hatch is exposed in the `AppBar`.

### Tasks
1. **Make `ChatSocket.disconnect()` Guaranteed Non-Blocking (`mobile/lib/core/network/ws_client.dart`):**
   - Wrap `subscription?.cancel()` and `channel?.sink.close()` in individual `try/catch` blocks with a `timeout(const Duration(seconds: 2))` so a stalled socket can never block logout.
   - Ensure `_connecting = false` and `_syncing = false` are reset cleanly on disconnect.
2. **Make `ApiClient.logout()` Fast and Guaranteed (`mobile/lib/core/network/api_client.dart`):**
   - Pass short timeouts (`sendTimeout: Duration(seconds: 3)`, `receiveTimeout: Duration(seconds: 3)`) on the `/api/v1/auth/logout` request.
   - Wrap `_tokenStore.clear()` in a `finally` block so local tokens are always wiped regardless of network outcome.
3. **Harden `AuthController.logout()` & `SessionRuntime.stop()` (`mobile/lib/core/providers.dart`):**
   - Guard `SessionRuntime.stop()` so concurrent/duplicate stop calls are idempotent and cancel/ignore any in-flight `_starting` boot.
   - Wrap every step in `AuthController.logout()` (`stop()`, `api.logout()`, `chatDao.clearAll()`) with bounded timeouts and `try/catch`, and execute `state = null` inside a `finally` block so the user is **always** signed out and GoRouter redirects to `/auth`.
   - Also invalidate user-scoped cached providers if needed so stale profile/people data never leaks into the next signed-in session.
4. **Fix `MyProfileScreen` Sign-Out Button UX & Reachability (`mobile/lib/features/profile/my_profile_screen.dart`):**
   - Add `bool _signingOut = false;`.
   - In `_signOut()`:
     - Guard `if (_signingOut) return;`.
     - Call `FocusManager.instance.primaryFocus?.unfocus();`.
     - Set `_signingOut = true`, run `await ref.read(authControllerProvider.notifier).logout()` inside `try/finally`, and navigate `context.go('/auth')` when mounted.
   - Add `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag` on the `ListView`, increase bottom padding (`AppSpacing.section + 32`), and wrap the "Sign out" button in `SafeArea(top: false)` with `SizedBox(width: double.infinity, height: 48)` for a clear, full-width tap target with a spinner while `_signingOut` is `true`.
   - Add a secondary Sign Out `IconButton(icon: Icon(Icons.logout))` (or confirmation dialog) in the `AppBar` (including on the `_loading` scaffold) so users can always log out immediately without scrolling or waiting on `/me`.
5. **Add Tests (`mobile/test/people_and_profile_test.dart` & `mobile/test/session_runtime_test.dart`):**
   - Widget test: render `MyProfileScreen`, scroll to and tap `"Sign out"`, verify `AuthController.logout()` runs, local DB + tokens clear, and route transitions to `/auth`.
   - Unit test: verify `AuthController.logout()` still completes and clears `state` even when `api.logout()` or socket disconnect throws or stalls.

### Acceptance Criteria
- Tapping "Sign out" on the Profile screen responds immediately with a loading indicator, clears tokens and local Drift tables, disconnects the WebSocket cleanly, and navigates to `/auth`.
- Logging out works reliably both online and offline (even when the backend is unreachable).
- Logging back in with a different account does not display any stale messages or profile state from the previous session.

---

## Phase 4: Fix Chat Auto-Scroll When Keyboard Appears

### Diagnosed Root Cause
1. In `mobile/lib/features/chat/chat_screen.dart` (lines 321–352), the message feed uses a standard forward `ListView.builder` (`reverse: false`).
2. When the user taps the composer `TextField`, the Android soft keyboard raises `MediaQuery.viewInsets.bottom` and shrinks the `Expanded` viewport from the bottom. Because a non-reversed `ListView` anchors its scroll offset to the **top**, the newest messages remain below the shrunk viewport and get covered by the keyboard.
3. `_ChatScreenState` does not react to keyboard metric changes (`WidgetsBindingObserver.didChangeMetrics()` / `viewInsets.bottom`), nor does it auto-scroll when new incoming messages arrive while the user is already at the bottom.

### Tasks
1. **Verify Android Soft Input Resize Mode (`mobile/android/app/src/main/AndroidManifest.xml`):**
   - Confirm `MainActivity` specifies `android:windowSoftInputMode="adjustResize"`.
   - Confirm `ChatScreen`'s `Scaffold` keeps `resizeToAvoidBottomInset: true`.
2. **Convert Message Feed to Bottom-Anchored Scroll (`mobile/lib/features/chat/chat_screen.dart`):**
   - Update `ListView.builder` to use `reverse: true` (the standard chat layout so offset `0.0` is always the newest message right above the composer):
     - Map index `0` to `items.last` (`final message = items[items.length - 1 - index];`).
     - Place the `"Load earlier messages"` button at the top of the thread (`index == items.length` when `_hasMoreHistory` is `true`).
     - Ensure short threads (1–3 messages) still look natural and remain anchored cleanly without awkward clipping when the keyboard opens (use `Align(alignment: Alignment.topCenter, child: ListView.builder(reverse: true, shrinkWrap: true, ...))` or standard `reverse: true` with `physics: AlwaysScrollableScrollPhysics()`—verify visually that keyboard opening pushes messages up smoothly in both short and long threads).
   - Update `_onScroll()`:
     - With `reverse: true`, the bottom of the chat is `position.pixels <= 40` (instead of `>= position.maxScrollExtent - 40`). Track `_isNearBottom = position.pixels <= 80`.
     - Trigger `markRead()` when `_isNearBottom` is true.
   - Update `_scrollToBottom()`:
     - Animate or jump to `0.0` (`_scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut)` or `jumpTo(0)` on initial open).
3. **Add Keyboard Metric & Focus Awareness (`mobile/lib/features/chat/chat_screen.dart`):**
   - Add a `FocusNode _composerFocusNode` passed to `_Composer`'s `TextField`, and mix in `WidgetsBindingObserver` in `_ChatScreenState`.
   - When the keyboard opens (`viewInsets.bottom` increases from `0`) and `_isNearBottom` is true (or the composer gains focus while near the bottom), ensure the list stays pinned to offset `0.0` after frame layout.
   - In `ref.listen(messagesProvider(widget.conversationId), ...)`, when the message count increases and either the newest message is from `selfId` or `_isNearBottom` is true, automatically scroll to the latest message.
4. **Add Widget Test (`mobile/test/`):**
   - Add a `chat_screen_test.dart` verifying:
     - Newest message renders at the bottom above the composer.
     - Simulating keyboard appearance (`viewInsets: EdgeInsets.only(bottom: 300)`) keeps the latest message visible above the composer without overflow errors.
     - Sending a message scrolls to the newest bubble.

### Acceptance Criteria
- Tapping the message input field smoothly pushes the latest chat messages up above the keyboard so the user can see the conversation while typing.
- Works seamlessly for both short conversations (few messages) and long conversations (scrollable history).
- Scrolling up to read older history does not forcefully yank the user back to the bottom when a message arrives unless they are already near the bottom or send a message themselves.

---

## Phase 5: Real-Time Incoming Message Notifications

### Current State & Architecture Decision
Currently, `mobile/lib/core/notifications/fcm_service.dart` is best-effort only (disabled whenever `google-services.json` is absent in local/LAN Android builds), does **not** subscribe to `FirebaseMessaging.onMessage` for foreground notifications, and has no local notification tray integration. Meanwhile, `ChatSocket` already delivers live messages in real time over WebSocket, and the backend already has FCM dispatch (`backend/src/lib/fcm.ts`).

To guarantee notifications work reliably on **both** self-hosted/LAN Android builds (without Firebase) and Firebase-enabled production builds (foreground + background + terminated), implement a **dual-layer notification system** powered by `flutter_local_notifications` + WebSocket events + FCM integration.

### Tasks
1. **Dependencies & Android Gradle / Manifest Setup:**
   - Add `flutter_local_notifications` to `mobile/pubspec.yaml` and run `flutter pub get`.
   - In `mobile/android/app/build.gradle.kts`:
     - Enable core library desugaring (`isCoreLibraryDesugaringEnabled = true` in `compileOptions`) and add `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")` (required by `flutter_local_notifications` on Android).
   - In `mobile/android/app/src/main/AndroidManifest.xml`:
     - Confirm `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` and `<uses-permission android:name="android.permission.VIBRATE" />` are declared.
     - Add default FCM notification channel metadata (`com.google.firebase.messaging.default_notification_channel_id` = `cpchat_messages`).
2. **Create `mobile/lib/core/notifications/local_notification_service.dart`:**
   - Initialize `FlutterLocalNotificationsPlugin` with Android settings (`@mipmap/ic_launcher`).
   - Create a high-importance `AndroidNotificationChannel`:
     - ID: `cpchat_messages`
     - Name: `Messages`
     - Importance: `Importance.max` (enables heads-up banner, sound, and vibration).
   - Expose `requestPermission()` to prompt Android 13+ (API 33+) users for runtime `POST_NOTIFICATIONS` permission cleanly (independent of Firebase availability).
   - Expose `showMessageNotification({required String conversationId, required String title, required String body, String? messageId})`:
     - Deduplicate recently shown notifications by `messageId` (short in-memory LRU/TTL set, e.g., 60 seconds) so WebSocket + FCM never show duplicate banners for the same message.
     - Use a stable deterministic notification ID derived from `conversationId.hashCode` (or group notifications per conversation) and attach `payload: conversationId`.
   - Expose `cancelForConversation(String conversationId)` and `cancelAll()` (called on chat open and logout).
   - Expose a tap stream (`onNotificationTap` emitting `conversationId`) wired to `onDidReceiveNotificationResponse` plus cold-start `getNotificationAppLaunchDetails()`.
3. **Track Active Conversation & App Lifecycle (`mobile/lib/core/providers.dart`):**
   - Add `activeConversationIdProvider` (`NotifierProvider<ActiveConversationNotifier, String?>`) updated in `ChatScreen.initState()` / `dispose()`.
   - Add `appLifecycleProvider` (or track `AppLifecycleState` via `WidgetsBindingObserver` in `CpChatApp`) so notifications still fire if the user left `ChatScreen` open and backgrounded the app.
   - Implement clean suppression rules before displaying a notification:
     1. Skip if `message.senderId == currentUser?.id`.
     2. Skip if `currentUser?.status == 'dnd'` (honors the existing "Do Not Disturb — Push notifications are muted" setting).
     3. Skip if the app is in `AppLifecycleState.resumed` **and** `activeConversationId == message.conversationId`.
     4. Skip during historical bulk pagination/catch-up sync (`syncAll` / `loadOlder`); only trigger on live inbound `message` frames.
4. **Wire Live WebSocket Inbound Messages (`mobile/lib/core/network/ws_client.dart` & `mobile/lib/core/providers.dart`):**
   - Add an optional callback `onIncomingMessage` (or broadcast stream) on `ChatSocket` fired **after** E2EE decryption and `upsertServerMessage()` succeed for live WebSocket `message` events.
   - Format notification content safely:
     - **Direct chat:** Title = peer display name (`Name (nickname)` or `Name`), Body = decrypted text preview (`'Sent an image'` for `image`, `'Sent a file'` for `file`, `'Encrypted message'` only if undecryptable).
     - **Group chat:** Title = group name, Body = `'$senderName: $preview'`.
   - Never leak raw E2EE ciphertext into notification text.
5. **Wire FCM Foreground & Tap Routing (`mobile/lib/core/notifications/fcm_service.dart` & `mobile/lib/main.dart`):**
   - Subscribe to `FirebaseMessaging.onMessage` in `FcmService` and forward foreground FCM payloads to `LocalNotificationService.showMessageNotification(...)` (respecting the same suppression & deduplication rules).
   - In `CpChatApp` (`mobile/lib/main.dart`):
     - Initialize `LocalNotificationService` during bootstrap and request Android notification permission once authenticated.
     - Listen to `LocalNotificationService.onNotificationTap` (and check launch details) to navigate directly to `/conversations/$conversationId` via `routerProvider`.
     - Clear notifications for a conversation inside `ChatScreen._onOpen()` and clear all notifications inside `AuthController.logout()`.
6. **Backend Push Payload Alignment (if needed in `backend/src/gateway/chat-gateway.ts` & `backend/src/lib/fcm.ts`):**
   - Verify FCM sends include `android.notification.channel_id = 'cpchat_messages'` and `data: { conversation_id, message_id, sender_name, conversation_name, type }` so Android displays background/terminated pushes on the same high-priority channel.
   - Verify backend skips FCM dispatch when the recipient's presence status is `dnd`.
7. **Add Unit Tests (`mobile/test/`):**
   - Test notification suppression logic: own messages skipped, DND status skipped, active foreground conversation skipped, backgrounded active conversation notified, duplicate `messageId` deduplicated, raw ciphertext never leaked.

### Acceptance Criteria
- When User A sends a direct or group message to User B (who is on the chat list, another chat, or another tab), User B immediately sees a heads-up Android notification with sound/vibration, sender/group name, and readable preview.
- Tapping the notification opens the exact conversation (`/conversations/:id`) and clears its notification.
- Opening a conversation manually clears any active notification for that conversation.
- Users set to `Do Not Disturb` (`dnd`) do not receive notifications.
- Works on physical Android devices even without `google-services.json`, and seamlessly deduplicates when Firebase FCM is also configured.

---

## Phase 6: End-to-End Verification & Android Device Smoke Checklist

### Tasks
1. **Run Automated Verification Suites:**
   - Mobile:
     ```bash
     cd mobile && flutter analyze && flutter test
     ```
   - Backend (if backend notification payload/DND checks were updated):
     ```bash
     cd backend && npm run typecheck && npm run build && npm test
     ```
2. **Physical Android APK Build & Manual Smoke Verification:**
   - Build Android APK targeting your LAN backend (`flutter build apk --release --dart-define=API_BASE_URL=... --dart-define=WS_BASE_URL=...`).
   - Verify all 5 fixes end-to-end across two test accounts:
     1. **Personal Chat Preview:** Send/receive 1:1 messages, pull-to-refresh chat list, kill & relaunch app -> chat list shows decrypted plaintext preview, never `"Encrypted message"`.
     2. **Group Chat Header:** Open an existing group and a newly created group -> AppBar shows group name + member count, never a member's name; tapping header opens Group Info.
     3. **Logout:** Open Profile tab, tap `"Sign out"` -> signs out immediately to `/auth`, works even if airplane mode is enabled; signing into Account B shows zero leftover data from Account A.
     4. **Keyboard Auto-Scroll:** Open both a 2-message chat and a 40-message chat, tap the message box -> latest messages move up cleanly above the keyboard.
     5. **Incoming Notifications:** From Account A, message Account B while Account B is on the Chats/People/Profile screen or another thread -> heads-up notification pops up with readable preview; tapping it jumps straight to that chat; setting Account B to `DND` suppresses notifications.
3. **Documentation & Final Push:**
   - Update `mobile/README.md` with notification channel / Android 13+ permission notes if applicable.
   - Ensure `git status` is clean, commit final verification updates, and push to `main`.
