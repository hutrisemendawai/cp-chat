Create a detailed, phased bug-fix implementation plan in English and save it as `bugfix2.md` at the repository root. Do NOT modify any application source code yet—only investigate the codebase and write `bugfix2.md`.

### Bug Description
Consider two users, **User A** and **User B**:
- **User A** has added **User B** as a friend.
- **User B** has **NOT** added **User A** as a friend yet.
- **User A** initiates a direct chat and sends one or more messages to **User B** while **User B** has the app open.

**Current (Buggy) Behavior:**
On **User B**'s device, the chat UI (the Conversations/Chats list screen and/or the Chat screen) does **not** update in real time when **User A** sends messages.

**Expected Behavior:**
Even when **User B** has not added **User A** back, incoming messages from **User A** must arrive, decrypt, persist, and update **User B**'s UI in real time—both creating/updating the conversation entry on the Conversations list screen and updating the message list in real time if the Chat screen is open—with accurate sender metadata (display name, avatar) and decrypted message content.

### Mandatory Codebase Investigation
Before writing `bugfix2.md`, thoroughly trace the entire real-time delivery pipeline end-to-end across backend and mobile:
1. **Docs & Project Rules:**
   - `AGENTS.MD`, `docs/ws-protocol.md`, `docs/architecture.md`, `docs/e2ee.md`, `BUG.md`, `plan.md`
2. **Backend Real-Time Delivery, Conversations & Friends Flow:**
   - `backend/src/gateway/chat-gateway.ts`
   - `backend/src/gateway/connection-registry.ts`
   - `backend/src/gateway/inbound.ts`
   - `backend/src/lib/broker.ts`
   - `backend/src/domain/conversations.ts`
   - `backend/src/domain/messages.ts`
   - `backend/src/domain/friends.ts`
   - `backend/src/domain/member-cache.ts`
   - `backend/src/http/conversation-routes.ts`
   - `backend/src/http/friend-routes.ts`
   - `backend/src/http/message-routes.ts`
   - `backend/test/gateway.test.ts`, `backend/test/friends-and-search.test.ts`, `backend/test/messages.test.ts`
3. **Mobile WebSocket, Sync, Local DB, E2EE & UI Reactivity Flow:**
   - `mobile/lib/core/network/ws_client.dart`
   - `mobile/lib/core/network/api_client.dart`
   - `mobile/lib/core/providers.dart`
   - `mobile/lib/core/database/app_database.dart`
   - `mobile/lib/core/database/chat_dao.dart`
   - `mobile/lib/core/crypto/e2ee_manager.dart`
   - `mobile/lib/core/crypto/e2ee_service.dart`
   - `mobile/lib/features/conversations/conversations_screen.dart`
   - `mobile/lib/features/chat/chat_screen.dart`
   - `mobile/lib/features/chat/chat_controller.dart`
   - `mobile/lib/features/chat/conversation_metadata.dart`
   - `mobile/lib/features/people/people_controller.dart`
   - `mobile/lib/shared/widgets/direct_chat.dart`
   - `mobile/test/conversations_screen_test.dart`, `mobile/test/chat_screen_test.dart`, `mobile/test/chat_dao_test.dart`, `mobile/test/sync_recovery_test.dart`, `mobile/test/e2ee_delivery_test.dart`

### Root-Cause Areas You MUST Verify
Do not assume a single cause—inspect and confirm every layer of the stack:
1. **Backend WebSocket Fan-Out & Membership Cache:**
   - When User A creates a new direct conversation with User B, does the backend broadcast a real-time event (e.g., `conversation.created` / `conversation.upsert`) to User B's active WebSocket connections?
   - Does `chat-gateway.ts` / `member-cache.ts` / `broker.ts` properly resolve User B as a recipient for the newly created conversation, or is membership cached/stale or gated on mutual friendship or explicit room subscription?
   - Does `friends.ts` or `conversations.ts` restrict conversation visibility or event fan-out when friendship is one-way?
2. **Mobile WS Event Handling & Unknown Conversation Hydration:**
   - When User B receives a WebSocket message event for a `conversationId` that does **not** yet exist in User B's local Drift database (`chat_dao.dart`), what happens?
   - Check if the message is silently dropped, blocked by a foreign-key constraint, or persisted without upserting a corresponding row in the local `conversations` table.
   - Check whether the mobile client triggers an on-demand REST hydration (fetching the new conversation and/or sender's user profile) when an incoming message references an unknown `conversationId` or an unadded `senderId`.
3. **E2EE First-Contact Decryption:**
   - Check if `e2ee_manager.dart` / `e2ee_service.dart` fails or blocks when decrypting an initial message from a sender who is not yet in User B's local contacts/friends or has no pre-existing local session.
4. **Reactive UI & State Wiring (`ConversationsScreen` & `ChatScreen`):**
   - Check whether `ConversationsScreen`, `ChatScreen`, `chat_controller.dart`, and `conversation_metadata.dart` reactively observe Drift streams / Riverpod providers for newly created conversations and incoming messages from non-friends, including resolving sender display name/avatar when the sender is absent from the local friends list.
   - Check if an already-open `ChatScreen` (e.g., opened via user search/profile before or during the first message) updates immediately without requiring navigation away and back.
5. **Preserve Core Invariants:**
   - Maintain per-account data isolation (`mobile/lib/core/account/*`).
   - Maintain end-to-end encryption (E2EE) guarantees.
   - Ensure users can only receive events for conversations they are actually members of (no authorization regressions).

### Required Structure of `bugfix2.md`
Organize `bugfix2.md` into clear, actionable sections:
1. **Executive Summary & Exact Root Cause Analysis**
   - Provide a verified file-by-file trace showing exactly where the real-time update breaks (citing exact files, classes, methods, and event names) when User B has not added User A.
2. **Target Real-Time Architecture & Sequence Flow**
   - Step-by-step sequence covering: User A creates DM -> User A sends message -> Backend persists & fans out WS events -> User B receives WS event -> hydrates missing conversation/sender metadata if needed -> decrypts E2EE payload -> upserts conversation & message atomically in Drift DB -> UI updates reactively on both Conversations list and Chat screen.
3. **Phased Implementation Plan**
   - Break the fix into small, logically ordered, independently verifiable phases (e.g., Phase 1: Backend conversation/message real-time fan-out & cache invalidation; Phase 2: Mobile WS ingestion, unknown-conversation/sender hydration & Drift upsert; Phase 3: E2EE first-contact & UI reactivity parity; Phase 4: Automated test coverage).
   - For every phase, specify exact files to modify, concrete implementation details, and exact verification commands.
4. **Edge Cases & Concurrency Matrix**
   - Explicitly cover:
     - Burst of multiple rapid messages arriving before the first conversation hydration REST call finishes (in-flight deduplication/queueing so messages aren't lost or duplicated).
     - Sender not present in User B's local friends/contacts table (fallback/hydration for display name, username, avatar).
     - User B already viewing User A's chat screen vs. viewing the Conversations list vs. viewing another tab.
     - Reconnection / catch-up sync if User B briefly disconnects right when the new conversation is created.
     - Account switching / logged-out state isolation.
5. **Testing & Real-Device Verification Plan**
   - List backend Vitest tests (`gateway.test.ts`, `friends-and-search.test.ts`, `messages.test.ts`), Flutter tests (`chat_dao_test.dart`, `conversations_screen_test.dart`, `chat_screen_test.dart`, `sync_recovery_test.dart`), and a step-by-step 2-account manual verification checklist.
