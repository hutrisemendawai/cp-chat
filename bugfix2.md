# Bugfix Plan 2 — Real-Time Delivery for One-Way Friend / Unknown Direct Conversations

> **Execution Policy (`AGENTS.MD` Rule 0):** Never build any Android APK or App Bundle (`flutter build apk`, `flutter build appbundle`, `make mobile-apk`, Gradle `assemble*`/`bundle*`). Verify every phase strictly with automated checks: `cd backend && npm run typecheck && npm test` and `cd mobile && flutter analyze && flutter test`.

---

## 1. Executive Summary & Exact Root Cause Analysis

### 1.1 Problem Statement
Consider **User A** and **User B**:
- **User A** has added **User B** as a friend (`user_friends` has `(A, B)`).
- **User B** has **not** added **User A** as a friend yet (`user_friends` does not have `(B, A)`), and no direct conversation between A and B existed when User B's app last connected and ran `ChatSocket.syncAll()`.
- **User B** keeps the app open (WebSocket connected).
- **User A** initiates a direct chat with **User B** and sends one or more messages.

**Observed Buggy Behavior:** User B's **Conversations** list screen does not show the new chat (nor any preview or unread badge) in real time, and if User B opens or is already viewing the chat under transient/race conditions, header metadata, presence, unread bookkeeping, or first-reply E2EE peer resolution can be missing or stale until a manual pull-to-refresh or reconnect runs `syncAll()`.

### 1.2 Verified End-to-End Root Cause Breakdown

Every layer of the backend and mobile stack was traced end-to-end. The failure is caused by **five compounding defects** across backend event emission, mobile Drift persistence, mobile WebSocket/FCM hydration, live unread tracking, and reactive UI/E2EE wiring:

| # | Severity | Layer & Exact Location | Verified Defect | User-Visible Symptom |
|---|---|---|---|---|
| **RC-1** | **Critical** | `backend/src/http/conversation-routes.ts` (`POST /api/v1/conversations`, L100–107) & `backend/src/domain/conversations.ts` (`findOrCreateDirect`, L118–159) | Group creation (`input.type === 'group'`, L80–98) calls `members.invalidate(conversation.id)` and `announce(conversation.id, [request.userId, ...memberIds])` (broadcasting `{ type: 'conversation_updated', conversation_id }`). Direct creation (`input.type === 'direct'`, L100–107) calls **neither** `members.invalidate` **nor** `announce`. | User B's live WebSocket never learns that a new direct conversation was created by User A. |
| **RC-2** | **Critical (Primary Breakpoint)** | `mobile/lib/core/database/chat_dao.dart` (`upsertServerMessage`, L400–447; `_bumpConversationCursor`, L864–893) | `local_messages` has no foreign key to `local_conversations`, so incoming messages from User A **are** decrypted and inserted into `local_messages`. However, `_bumpConversationCursor` executes `if (existing == null) return;` (L868) and **never inserts a `local_conversations` row**. Because `ConversationsScreen` watches `chatDao.watchConversations()` (`local_conversations` only), the stream never emits. | User A's messages sit as orphaned rows in `local_messages`. User B's Conversations list stays completely unchanged until manual pull-to-refresh or reconnect (`syncAll()`). |
| **RC-3** | **Critical** | `mobile/lib/core/network/ws_client.dart` (`_handleMessage`, L686–726; `ingestFcmPush`, L736–850) & `mobile/lib/core/notifications/background_push_handler.dart` (`_processUnderLock`, L402–537) | When a live WS `message` frame (or v2 data-only FCM push) arrives for an unknown `conversation_id`, `ChatSocket` never checks whether `local_conversations` contains that id and never triggers an on-demand `GET /api/v1/conversations/:id` hydration. Additionally, `_decryptForStorage` (L930–931) checks `await _dao.conversationType(message.conversationId) == 'group'`, which evaluates `null == 'group' -> false` (blindly assuming direct chat if unknown), and `MessageNotifier`'s `resolveNames` (`providers.dart`, L404–414) returns `null` when the row is absent. | Even if `conversation_updated` were missed (e.g., reconnect race), live messages never self-heal the missing conversation row or hydrate User A's name, nickname, and avatar. |
| **RC-4** | **High** | `mobile/lib/core/database/chat_dao.dart` (`_bumpConversationCursor`, L864–893; `_upsertConversation`, L230–231) | 1. `_bumpConversationCursor` updates `lastSeq`, `updatedAt`, and `lastMessagePreview`, but **never increments `unreadCount`** on incoming messages from other users when the chat is not currently open. 2. In `_upsertConversation` (L231), `final unreadCount = effectiveClearedSeq >= lastSeq ? 0 : item.unreadCount;` overwrites `unreadCount` even when `stale == true` (`item.lastSeq < existing.lastSeq`), so a `conversation_updated` REST response (`lastSeq: 0, unreadCount: 0`) that resolves after WS message `seq: 1` wipes the unread badge back to `0`. | Newly created chats (and existing chats receiving live WS messages) fail to display or retain an accurate real-time unread badge on `ConversationsScreen`. |
| **RC-5** | **High** | `mobile/lib/features/chat/chat_screen.dart` (L324–338), `mobile/lib/features/chat/conversation_metadata.dart` (L8–24), `mobile/lib/features/chat/chat_controller.dart` (L44–64), `mobile/lib/core/crypto/e2ee_manager.dart` (L486–488) | 1. `conversationMetadataProvider` is a non-autoDispose `FutureProvider.family` that caches `null` permanently on a transient/offline failure and is never invalidated when `ChatSocket._handleConversationUpdated` refreshes a conversation. 2. `ChatScreen.build` only passes `peer?.user.id` (from `metadata.value`) — ignoring `cached?.peerId` — to `e2eeManager.rememberConversation` (L324–332) and `presenceProvider` (L335–337). 3. If User B immediately replies on a newly hydrated/provisional chat before `conversationMetadataProvider` resolves and `peerId` is null, `E2eeManager.encryptForConversation` (L487: `if (target == null) return plaintext;`) would **silently downgrade an outgoing 1:1 reply to plaintext** instead of resolving `peerId` or failing closed. | Open `ChatScreen` misses live presence subtitle when metadata is loading/cached-null, fails to refresh stale metadata on WS updates, and risks plaintext downgrade on immediate first-contact reply. |

### 1.3 Verified Non-Causes (Confirmed Healthy)
To avoid unnecessary changes, the following components were inspected and confirmed **not** to gate or break one-way-friend delivery:
1. **Friendship Model (`backend/src/domain/friends.ts`, `backend/src/http/friend-routes.ts`):** `user_friends` is strictly directed `(user_id, friend_id)`. Neither `conversations.ts`, `messages.ts`, `keys.ts`, nor `chat-gateway.ts` checks `user_friends` when creating a direct conversation, querying `GET /api/v1/conversations/:id`, persisting messages, or fanning out WebSocket frames.
2. **Backend Message Fan-Out & Membership Cache (`backend/src/gateway/chat-gateway.ts` L522–533, `backend/src/domain/member-cache.ts`, `backend/src/lib/broker.ts`, `backend/src/gateway/connection-registry.ts`):** When User A sends a `send` frame, `ChatGateway.deliverStoredInner` reads `ctx.members.ids(conversationId)` (which queries `conversation_members` on cache miss, returning `[userA, userB]`) and routes the `message` frame via `this.route(userB, messageEvent)` to every live device of User B across gateway replicas.
3. **E2EE First-Contact Decryption (`mobile/lib/core/crypto/e2ee_manager.dart` L379–393, `mobile/lib/core/crypto/e2ee_service.dart` L617–641 & L714–750):** `E2eeManager._plaintextFor` resolves `target = peerId ?? senderId ?? await _peerIdFor(conversationId)`. Because `ChatSocket._decryptForStorage` passes `senderId: message.senderId`, User B does **not** need User A in local contacts or an existing session: User A's opening message carries X3DH initiation context (`ek`, `spk`, `opk`), so `E2eeService.decrypt` derives `_responderSession` from User B's local keys (`LocalKeyMaterial`), decrypts the AES-256-GCM ciphertext, and persists the session under `acct.<accountId>.e2ee_sessions`.
4. **Backend Presence & Profile Endpoints (`backend/src/domain/presence.ts` L118–132, `backend/src/http/presence-routes.ts`, `backend/src/http/user-routes.ts`):** Once `conversation_members` contains both A and B, `sharedPeerIds(A)` includes B for future presence transitions, and `GET /api/v1/conversations/:id` / `GET /api/v1/presence/:id` already return User A's display name, nickname, avatar key, and effective presence status without requiring B to have added A as a friend.
5. **Local SQLite Schema (`mobile/lib/core/database/app_database.dart`):** `LocalMessages` does not declare a SQLite `REFERENCES local_conversations(id)` foreign key, so incoming messages are not blocked by `PRAGMA foreign_keys = ON`.

### 1.4 Documentation Discrepancy Noted
- `docs/ws-protocol.md` (L254–258) currently describes `conversation_updated` as group-only and states *"Clients must ignore it for conversations they do not have locally."* In fact, `ChatSocket._handleConversationUpdated` (`ws_client.dart` L1021–1047) **already** fetches unknown conversations via `GET /api/v1/conversations/:id` and upserts them into Drift, deleting locally only on `403`/`404`. `docs/ws-protocol.md` must be updated to codify direct-chat creation announcements and unknown-conversation hydration.

---

## 2. Target Real-Time Architecture & Sequence Flow

### 2.1 Dual-Path Defense-in-Depth Strategy
Relying solely on `conversation_updated` is fragile if a message arrives before the REST fetch completes or if the announcement races with a reconnect. Relying solely on lazy message hydration delays empty-DM creation awareness and misses group/direct metadata on arrival. Therefore, the target design combines **both**:

1. **Proactive Server Announcement (Fast Path):**
   - `POST /api/v1/conversations` (for newly created `direct` chats, matching `group` chats) invalidates `MemberCache` and broadcasts `{ type: "conversation_updated", conversation_id }` to `[creatorId, otherUserId]`.
   - `ChatGateway.deliverStoredInner` adds backward-compatible metadata fields to the `message` WS frame: `conversation_type` (`"direct" | "group"`), `sender_avatar_url` (`string | null`), and `conversation_name` (`string | null` for groups).
2. **Atomic Provisional Upsert + Single-Flight Authoritative Hydration (Guaranteed Self-Healing Path):**
   - When `ChatSocket._handleMessage` (or `ingestFcmPush` / `BackgroundPushHandler`) persists an incoming message for a `conversation_id` not yet in `local_conversations`, `ChatDao.upsertServerMessage` **atomically** inserts a provisional `LocalConversations` row in the same SQLite transaction using the message frame's metadata (`conversation_type`, `sender_id`, `sender_name`, `sender_avatar_url`, decrypted preview, `lastSeq`, `unreadCount`, `updatedAt`).
   - User B's `ConversationsScreen` updates **immediately (0 extra round trips)** via `watchConversations()`.
   - In parallel, `ChatSocket` triggers a **single-flight** REST hydration (`GET /api/v1/conversations/:id`) outside the per-conversation message lock (never deadlocking `_serializeMessages`), then upserts the authoritative `Conversation` summary (`peerName`, `peerNickname`, `peerAvatarUrl`, `type`, `members`, `clearedSeq`, `lastReadSeq`) while preserving any newer local `lastSeq`, `preview`, `updatedAt`, and `unreadCount`.
   - Once hydrated (or on any `conversation_updated`), `ChatSocket` emits `conversationId` on `conversationUpdatedEvents`, causing Riverpod to invalidate `conversationMetadataProvider(conversationId)` so an open `ChatScreen` refreshes members/header/presence immediately.

### 2.2 End-to-End Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant A as User A (Mobile)
    participant API as Backend REST (:8080)
    participant DB as PostgreSQL + Redis
    participant GW as Chat Gateway (:8081)
    participant B_WS as User B ChatSocket
    participant B_E2EE as User B E2eeManager
    participant B_DB as User B Drift SQLite
    participant B_UI as User B UI (Chats / ChatScreen)

    A->>API: POST /api/v1/conversations {type: direct, member_ids: [B]}
    API->>DB: findOrCreateDirect(A, B) -> {conversation, created: true}
    API->>DB: MemberCache.invalidate(convId)
    API->>GW: broker.publishBroadcast([A, B], {type: conversation_updated, conversation_id})
    API-->>A: 201 ConversationSummary

    par Proactive DM hydration on User B
        GW-->>B_WS: WS frame {type: conversation_updated, conversation_id}
        B_WS->>API: Single-flight GET /api/v1/conversations/:id
        API-->>B_WS: 200 ConversationSummary (A's name, nickname, avatar, presence)
        B_WS->>B_DB: upsertConversation(summary, selfId: B) [preserves newer local seq/unread]
        B_DB-->>B_UI: watchConversations() / watchConversation() emits
        B_WS-->>B_UI: invalidate conversationMetadataProvider(convId)
    and User A sends first encrypted message immediately
        A->>GW: WS frame {type: send, conversation_id, client_msg_id, msg_type: text, content: e2ee:v1:...}
        GW->>DB: messages.append() -> seq=1; members.ids() -> [A, B]
        GW-->>A: WS frame {type: status, seq: 1, status: sent}
        GW-->>B_WS: WS frame {type: message, seq: 1, sender_id: A, sender_name, sender_avatar_url, conversation_type: direct, content: e2ee:v1:...}
        B_WS->>B_E2EE: plaintextFor(clientMsgId, convId, ciphertext, isGroup: false, senderId: A)
        B_E2EE-->>B_WS: X3DH responder derive + AES-GCM decrypt -> plaintext
        B_WS->>B_DB: TX: upsertServerMessage + atomic provisional conversation insert (if absent) + unreadCount increment (if conv not active)
        B_DB-->>B_UI: watchConversations() + watchMessages() emit decrypted text & unread badge immediately
        B_WS->>GW: WS frame {type: ack, conversation_id, seq: 1, status: delivered}
        alt Conversation was absent or provisional
            B_WS->>API: Single-flight GET /api/v1/conversations/:id (deduped with proactive call)
            API-->>B_WS: 200 ConversationSummary
            B_WS->>B_DB: upsertConversation(summary, selfId: B) [enriches nickname/avatar, keeps unread>=1 & decrypted preview]
            B_DB-->>B_UI: watchConversations() / watchConversation() emits enriched row
        end
    end
```

---

## 3. Phased Implementation Plan

### Phase 1: Backend Direct-Chat Announcement, Cache Invalidation & Enriched `message` Frame

**Goal:** Ensure User B's connected sockets are notified immediately when User A creates a new direct conversation, eliminate any stale `MemberCache` window, and include additive display/type hints on live `message` frames.

#### Files to Modify
1. `backend/src/domain/conversations.ts`
   - Update `findOrCreateDirect(currentUserId, otherUserId)` (L118–159) — or introduce `findOrCreateDirectWithStatus(...)` returning `{ conversation: ConversationRow; created: boolean }` (while keeping `findOrCreateDirect` delegating or updating the single caller at `conversation-routes.ts:104`).
   - `created` is `true` iff `insert.rows[0]` succeeded (`ON CONFLICT DO NOTHING RETURNING ...` returned a row), and `false` when the pre-existing `direct_key` row was returned.
2. `backend/src/http/conversation-routes.ts`
   - In `POST /api/v1/conversations` (`input.type === 'direct'`, L100–107):
     - Call `const { conversation, created } = await conversations.findOrCreateDirect(request.userId, otherId);`.
     - When `created` is `true`:
       - Call `await members.invalidate(conversation.id);`
       - Call `await announce(conversation.id, [request.userId, otherId]);` (reuses existing `announce()` helper at L192–200, which publishes `{ type: 'conversation_updated', conversation_id }` to `ctx.broker.publishBroadcast` keyed by `c:${conversation.id}`).
   - **Security invariant:** `announce` targets strictly `[request.userId, otherId]` (the exact two verified members inserted into `conversation_members`). Never broadcast to non-members.
3. `backend/src/gateway/chat-gateway.ts`
   - In `deliverStoredInner` (L469–485):
     - `conversation` (`getRow`) and `sender` (`findById`) are **already loaded** on L469–470 (zero extra DB queries!).
     - Add additive, backward-compatible fields to `messageEvent`:
       - `conversation_type: conversation?.type ?? 'direct'`
       - `conversation_name: conversation?.type === 'group' ? conversation.name : null`
       - `sender_avatar_url: sender?.avatar_url ?? null`
4. `docs/ws-protocol.md`
   - Update `### message` (L180–205) to document optional additive fields `conversation_type`, `conversation_name`, and `sender_avatar_url`.
   - Update `### conversation_updated` (L245–259) to clarify it is emitted for newly created direct conversations as well as group creation/edits/membership changes, and that clients should fetch & upsert unknown conversations (and delete locally only on `403`/`404`).

#### Verification Commands (Phase 1)
```bash
cd backend && npm run typecheck && npm test
```

---

### Phase 2: Mobile Drift Atomic Provisional Upsert & Real-Time Unread Bookkeeping (`ChatDao`)

**Goal:** Guarantee that persisting an incoming server message **never** leaves an orphaned row without a `local_conversations` entry, and that `unreadCount` stays accurate in real time without being clobbered by racing/stale REST summaries.

#### Files to Modify
1. `mobile/lib/core/database/chat_dao.dart`
   - Introduce a small immutable value class `ProvisionalConversationHint`:
     ```dart
     class ProvisionalConversationHint {
       const ProvisionalConversationHint({
         this.type = 'direct',
         this.conversationName,
         this.peerId,
         this.peerName,
         this.peerAvatarUrl,
       });
       final String type;
       final String? conversationName;
       final String? peerId;
       final String? peerName;
       final String? peerAvatarUrl;
     }
     ```
   - Update `upsertServerMessage` (L400–447) signature with backward-compatible optional parameters:
     ```dart
     Future<void> upsertServerMessage(
       Message message, {
       String status = 'sent',
       ProvisionalConversationHint? ensureConversation,
       bool incrementUnread = false,
     })
     ```
   - Inside `upsertServerMessage`'s existing SQLite transaction:
     - Determine `isNewIncomingRow`: `existing == null` (or `existing.seq == null` — note own optimistic sends won't set `incrementUnread: true`).
     - Pass `ensureConversation`, `incrementUnread: incrementUnread && isNewIncomingRow`, to `_bumpConversationCursor`.
   - Update `_bumpConversationCursor` (L864–893):
     - If `existing == null`:
       - If `ensureConversation == null`, return (preserves existing unit-test behavior for direct DAO tests that intentionally omit conversation setup).
       - Otherwise, insert a provisional `LocalConversationsCompanion.insert(...)` atomically inside the same transaction:
         - `id: message.conversationId`
         - `type: ensureConversation.type`
         - `name: Value(ensureConversation.type == 'group' ? ensureConversation.conversationName : null)`
         - `peerId: Value(ensureConversation.type == 'group' ? null : ensureConversation.peerId)`
         - `peerName: Value(ensureConversation.type == 'group' ? null : ensureConversation.peerName)`
         - `peerAvatarUrl: Value(ensureConversation.type == 'group' ? null : ensureConversation.peerAvatarUrl)`
         - `lastMessagePreview: Value(_contentPreview(message.type, content))`
         - `lastSeq: Value(message.seq)`
         - `lastReadSeq: const Value(0)`
         - `clearedSeq: const Value(0)`
         - `unreadCount: Value(incrementUnread ? 1 : 0)`
         - `updatedAt: message.createdAt`
     - If `existing != null`:
       - Compute `nextUnread`: if `incrementUnread && message.seq > math.max(existing.lastReadSeq, existing.clearedSeq)`, `existing.unreadCount + 1`, else `existing.unreadCount`.
       - Include `unreadCount: Value(nextUnread)` in the `db.update(db.localConversations)` write alongside `lastSeq`, `updatedAt`, and `lastMessagePreview`.
   - Fix stale-summary unread regression in `_upsertConversation` (L230–231):
     - Currently:
       ```dart
       final lastReadSeq = math.max(item.lastReadSeq, effectiveClearedSeq);
       final unreadCount = effectiveClearedSeq >= lastSeq ? 0 : item.unreadCount;
       ```
     - Update to preserve local `lastReadSeq` monotonically when `preserveLocalCursor && existing != null`:
       ```dart
       final lastReadSeq = math.max(
         preserveLocalCursor && existing != null ? existing.lastReadSeq : 0,
         math.max(item.lastReadSeq, effectiveClearedSeq),
       );
       final int unreadCount;
       if (effectiveClearedSeq >= lastSeq || lastReadSeq >= lastSeq) {
         unreadCount = 0;
       } else if (stale) {
         // REST summary predates live WS messages already persisted locally.
         unreadCount = math.max(existing.unreadCount, item.unreadCount);
       } else {
         unreadCount = item.unreadCount;
       }
       ```
     - Also ensure `peerNickname` / `peerName` / `peerAvatarUrl` from the authoritative `Conversation` always overwrite provisional values (already true on L237–240 because `_peerName(item, selfId) ?? existing?.peerName` prefers the fresh server value). Note: if a provisional row had `"Alice (Ali)"` in `peerName` and the server returns `name: "Alice", nickname: "Ali"`, L237 sets `peerName = "Alice"` and L239 sets `peerNickname = "Ali"` — cleanly replacing the temporary formatted label with structured fields!

#### Verification Commands (Phase 2)
```bash
cd mobile && flutter analyze && flutter test test/chat_dao_test.dart
```

---

### Phase 3: Mobile `ChatSocket` & `BackgroundPushHandler` Unknown-Conversation Single-Flight Hydration & Concurrency Safety

**Goal:** Wire single-flight on-demand conversation hydration into `ChatSocket` (live WS + `conversation_updated` + `ingestFcmPush`) and `BackgroundPushHandler`, prevent duplicate REST calls or `_serializeMessages` deadlocks under message bursts, and expose a stream for UI metadata invalidation.

#### Files to Modify
1. `mobile/lib/core/network/ws_client.dart`
   - Add constructor callback:
     ```dart
     final String? Function()? activeConversationId;
     ```
     (Wired in `providers.dart` to `() => ref.read(activeConversationIdProvider)` so `ChatSocket` knows whether a live incoming message is for the chat already open on screen and should NOT increment `unreadCount`.)
   - Add broadcast stream for conversation updates:
     ```dart
     final StreamController<String> _conversationUpdatedController =
         StreamController<String>.broadcast();
     Stream<String> get conversationUpdatedEvents =>
         _conversationUpdatedController.stream;
     ```
     Close `_conversationUpdatedController` in `dispose()`.
   - Add single-flight hydration tracking (cleared in `disconnect()`):
     ```dart
     final Map<String, Future<Conversation?>> _inFlightHydrations = {};
     final Set<String> _pendingHydrations = {};
     ```
   - Implement `Future<Conversation?> _fetchConversationSingleFlight(String conversationId, int disconnectToken)`:
     - Must run **outside** `_serializeMessages(conversationId, ...)` to prevent deadlocks!
     - If `_inFlightHydrations[conversationId]` exists, await and return it.
     - Otherwise invoke `_api.conversation(conversationId)`, store in `_inFlightHydrations[conversationId]`, remove in `whenComplete`.
     - On `ApiException` with `403`/`404`: delete local conversation via `_dao.deleteConversation(conversationId)` and remove from `_pendingHydrations`.
     - On transient network/5xx error: add `conversationId` to `_pendingHydrations` (so next incoming message or reconnect `syncAll()` retries hydration) and return `null`.
   - Implement `Future<void> _hydrateConversation(String conversationId, {bool runSummarySync = false})`:
     - Captures `tokenBefore = _disconnectToken` and `selfId = await _selfId()`.
     - Calls `_fetchConversationSingleFlight(conversationId, tokenBefore)`.
     - Checks `if (_scopeClosed || tokenBefore != _disconnectToken) return;`.
     - Awaits `_syncBarrier?.future` if active.
     - Enters `_serializeMessages(conversationId, () async { ... })`:
       - Calls `await _dao.upsertConversation(conversation, selfId: selfId);`
       - Removes `conversationId` from `_pendingHydrations`.
       - If `runSummarySync`, calls `await _syncSummary(conversation, disconnectToken: tokenBefore);`.
     - Emits `conversationId` on `_conversationUpdatedController` (if not `_scopeClosed`).
   - Update `_handleConversationUpdated` (L1021–1047) to delegate directly to `_hydrateConversation(conversationId, runSummarySync: true)`.
   - Update `_handleMessage` (L686–726):
     - Extract additive frame hints: `senderName = frame['sender_name'] as String?`, `senderAvatarUrl = frame['sender_avatar_url'] as String?`, `conversationType = frame['conversation_type'] as String?`, `conversationName = frame['conversation_name'] as String?`.
     - Resolve `selfId = await _selfId()`.
     - Compute `isFromOther = selfId == null || message.senderId != selfId`.
     - Compute `isActiveChat = activeConversationId?.call() == message.conversationId`.
     - Inside `_serializeMessages(message.conversationId, () async { ... })`:
       - Check `final existingConv = await _dao.conversation(message.conversationId);`.
       - Track `needsHydration = existingConv == null || _pendingHydrations.contains(message.conversationId);`.
       - Build `ProvisionalConversationHint? hint`: when `existingConv == null`, build from `conversationType ?? 'direct'`, `conversationName`, `peerId: isFromOther ? message.senderId : null`, `peerName: isFromOther ? senderName : null`, `peerAvatarUrl: isFromOther ? senderAvatarUrl : null`.
       - Pass `conversationTypeOverride: conversationType` into `_persistServerMessage` -> `_decryptForStorage` so `isGroup` is accurate even before REST hydration finishes!
       - Pass `ensureConversation: hint` and `incrementUnread: isFromOther && !isActiveChat` into `_persistServerMessage` -> `_dao.upsertServerMessage`.
       - If `message.seq > cursor + 1`, `_syncConversation` runs first and also passes `ensureConversation: hint` / `incrementUnread` for newly synced non-historic gap messages (or triggers `_hydrateConversation` right after).
     - **Outside** `_serializeMessages`: if `needsHydration && !_scopeClosed`, fire `unawaited(_hydrateConversation(message.conversationId, runSummarySync: false))` (single-flight deduped across rapid bursts!).
     - Note on `_emitIncoming` (`MessageNotifier`): because the provisional conversation row is ALREADY committed atomically with the message, `MessageNotifier`'s `resolveNames(conversationId)` immediately finds the row with accurate `isGroup` and `displayName`!
   - Update `ingestFcmPush` (L736–850) identically:
     - Build `ProvisionalConversationHint` from `data['conversation_type']`, `data['conversation_name']`, `senderId`, `senderName`, `sender_avatar_url`.
     - Pass `ensureConversation` + `incrementUnread` when persisting.
     - Trigger `unawaited(_hydrateConversation(conversationId, runSummarySync: false))` when the conversation was absent locally.
   - Update `syncAll` (L259–305):
     - Clear `_pendingHydrations` for every conversation returned by `_api.conversations(limit: 100)`.
   - Update `handleServerFrameForTesting` (L1074–1086):
     - Add `case 'conversation_updated': await _handleConversationUpdated(frame);`.
2. `mobile/lib/core/notifications/background_push_handler.dart`
   - In `_processUnderLock` (L402–537) and `_syncGapOrOversized` (L553–729):
     - When `conv == null`, construct `ProvisionalConversationHint` from `ParsedFcmMessage` (`type: parsed.conversationType`, `conversationName: parsed.conversationName`, `peerId: parsed.senderId != userId ? parsed.senderId : null`, `peerName: parsed.senderName`) and pass `ensureConversation: hint, incrementUnread: parsed.senderId != userId` to `dao.upsertServerMessage(...)`.
     - This ensures that if User B's app was terminated during first contact and User B reopens it offline (or before `syncAll()` finishes), the conversation row + decrypted preview + unread badge are already visible on `ConversationsScreen`.

#### Verification Commands (Phase 3)
```bash
cd mobile && flutter analyze && flutter test test/sync_recovery_test.dart test/e2ee_delivery_test.dart test/background_push_decrypt_test.dart
```

---

### Phase 4: Mobile E2EE First-Contact Hardening & Reactive UI Parity

**Goal:** Eliminate every UI and E2EE edge case when User B opens or already has `ChatScreen` open during first contact from a non-friend.

#### Files to Modify
1. `mobile/lib/core/providers.dart`
   - In `chatSocketProvider` (L316–357):
     - Pass `activeConversationId: () => ref.read(activeConversationIdProvider)` into `ChatSocket(...)`.
     - Subscribe to `socket.conversationUpdatedEvents` (cancelling the subscription in `ref.onDispose`) so every hydrated/updated conversation invalidates `conversationMetadataProvider(conversationId)` (only while `scope == null || scope.isOpen`).
2. `mobile/lib/features/chat/conversation_metadata.dart`
   - Keep `conversationMetadataProvider` account-scoped (`ref.watch(accountScopeProvider)`).
   - Ensure transient network failures (`DioException` / non-401 `ApiException`) do not leave `ChatScreen` stuck forever with `null`:
     - When `ChatSocket.connection` transitions to `SocketState.connected` or `conversationUpdatedEvents` emits `conversationId`, invalidating `conversationMetadataProvider(conversationId)` refreshes it cleanly.
     - Optionally switch to `FutureProvider.autoDispose.family` (or keep invalidated via `conversationUpdatedEvents` + reconnect) so navigating back into a chat after an offline open always retries metadata fetch.
3. `mobile/lib/features/chat/chat_screen.dart`
   - Unify direct-chat peer resolution (L311–346):
     - Compute `final peerUserId = !isGroup ? (peer?.user.id ?? cached?.peerId) : null;` **before** E2EE registration and presence lookup.
     - Register E2EE peer id whenever `peerUserId != null` (not only when `peer != null`):
       ```dart
       if (!isGroup && selfId != null && peerUserId != null) {
         ref.read(e2eeManagerProvider).rememberConversation(
               widget.conversationId,
               selfId: selfId,
               peerId: peerUserId,
             );
       }
       ```
     - Watch live presence whenever `peerUserId != null`:
       ```dart
       final presence = !isGroup && peerUserId != null
           ? ref.watch(presenceProvider(peerUserId))
           : null;
       ```
     - Verify `senderNames` on L349–352: in direct chats, incoming bubbles do not need a sender label (only groups do, per comment on L348: `if (isGroup && metadata.value != null)` — or keep existing group behavior while falling back cleanly if `metadata` is loading).
     - Ensure `_onOpen` (`chat_screen.dart` L108–121) calls `markRead()` **after** `syncAll()` (already does) AND note that `ref.listen(messagesProvider(...))` (L354–366) calls `markRead()` whenever new live messages arrive while `ChatScreen` is open.
4. `mobile/lib/features/chat/chat_controller.dart` & `mobile/lib/core/crypto/e2ee_manager.dart`
   - **Prevent plaintext downgrade on immediate first-contact reply:**
     - In `ChatController.sendText` (`chat_controller.dart` L49–63):
       - Resolve `peerId`: first check `conversation?.peerId`. If `!isGroup && peerId == null`, fetch `final fresh = await _api.conversation(_conversationId);` and upsert it into `dao` so `peerId` is resolved deterministically before calling `encryptForConversation`!
       - If `!isGroup && peerId == null` still holds (e.g., offline and unknown peer), throw `const E2eeSendException()` rather than sending plaintext.
     - In `E2eeManager.encryptForConversation` (`e2ee_manager.dart` L486–488):
       - Confirm `if (target == null) return null;` (fail closed for direct chats instead of `return plaintext;`) once all callers pass `peerId` (verify no existing unit test relies on `target == null` returning plaintext; if any does, fix in `ChatController.sendText` and guard with unit tests!).

#### Verification Commands (Phase 4)
```bash
cd mobile && flutter analyze && flutter test
```

---

### Phase 5: Automated Test Coverage

**Goal:** Lock in permanent regression coverage for one-way-friend real-time delivery, bursts, E2EE first-contact, unread badges, and account isolation across both backend and mobile suites.

#### Files to Modify
1. `backend/test/gateway.test.ts`
2. `backend/test/friends-and-search.test.ts`
3. `backend/test/messages.test.ts`
4. `mobile/test/chat_dao_test.dart`
5. `mobile/test/sync_recovery_test.dart`
6. `mobile/test/e2ee_delivery_test.dart`
7. `mobile/test/conversations_screen_test.dart`
8. `mobile/test/chat_screen_test.dart`
9. `mobile/test/background_push_decrypt_test.dart`

*(Detailed test cases are listed in Section 5 below.)*

#### Verification Commands (Phase 5)
```bash
cd backend && npm run typecheck && npm test
cd mobile && flutter analyze && flutter test
```

---

## 4. Edge Cases & Concurrency Matrix

| # | Scenario | Risk / Failure Mode Without Handling | Concrete Mitigation in Plan |
|---|---|---|---|
| **E-1** | **Burst of rapid messages (e.g., 5–10 messages in <100 ms) before `GET /api/v1/conversations/:id` finishes** | 1. Five parallel identical HTTP requests hit `/conversations/:id`. 2. Deadlock if hydration acquires `_serializeMessages` while already inside `_serializeMessages`. 3. Stale `GET /conversations/:id` (captured at `last_seq=0, unread=0` from `conversation_updated`) overwrites `lastSeq`, `lastMessagePreview`, or `unreadCount` after WS `seq=1..5` already persisted. 4. Out-of-order decryption corrupts symmetric ratchet. | 1. Single-flight map `_inFlightHydrations[conversationId]` deduplicates all concurrent REST fetches into one call. 2. REST fetch runs **outside** `_serializeMessages`; only the Drift upsert runs inside `_serializeMessages`. 3. `_serializeMessages` preserves strict FIFO decryption order (`seq 1 -> 5`). 4. `ChatDao._upsertConversation` detects `stale` (`item.lastSeq < existing.lastSeq`) and preserves local `lastSeq`, decrypted `lastMessagePreview`, `updatedAt`, and `math.max(existing.unreadCount, item.unreadCount)`. |
| **E-2** | **Sender not in User B's local friends/contacts list** | Conversations list or ChatScreen header falls back to `"Chat"`, missing avatar, or wrong display name. | Backend `GET /api/v1/conversations/:id` joins `users` directly (independent of `user_friends`) and returns full `PublicUser` (`name`, `nickname`, `username`, `avatar_url`, `effective_status`, `online`). Provisional upsert uses additive WS fields (`sender_name`, `sender_avatar_url`) immediately; REST hydration upgrades to structured `peerName`, `peerNickname`, `peerAvatarUrl`. If REST fails transiently, `_pendingHydrations` retries on next message or reconnect. |
| **E-3** | **User B's active UI location when message arrives:** (a) Viewing `ConversationsScreen`, (b) Already viewing User A's `ChatScreen` (e.g., opened via user search/profile before first message), (c) Viewing `People` or `My Profile` tab, (d) App backgrounded/terminated (v2 FCM push) | (a) Chat fails to appear or unread badge stays `0`. (b) `ChatScreen` header missing presence/avatar or `unreadCount` wrongly increments while user is reading the chat. (c) Tab switch shows empty Chats list. (d) Opening app offline after terminated push shows no conversation row. | (a) Atomic provisional insert + REST hydration updates `watchConversations()` immediately with `unreadCount = 1..N`. (b) `activeConversationIdProvider == conversationId` suppresses `unreadCount` increment; `watchMessages()` renders bubbles immediately; `ref.listen` calls `markRead()`; `conversationUpdatedEvents` invalidates `conversationMetadataProvider` and `ChatScreen` uses `peer?.user.id ?? cached?.peerId` for presence & E2EE. (c) Drift DB updates in background regardless of active tab; `ConversationsScreen` is backed by `watchConversations()`. (d) `ingestFcmPush` and `BackgroundPushHandler` both pass `ProvisionalConversationHint` so Drift already holds the conversation + decrypted message. |
| **E-4** | **Brief disconnect / reconnect right as User A creates the DM and sends messages** | User B misses `conversation_updated` and/or `message(seq=1)` while disconnected; upon reconnect, `message(seq=2)` arrives first. | On reconnect, `ChatSocket._open` runs `syncAll()` (fetching `GET /api/v1/conversations` + contiguous `/sync` from `0`) before live traffic finishes unblocking `_syncBarrier`. If a live frame with `seq=2` still arrives first (`seq > cursor + 1`), `_handleMessage` runs `_syncConversation(convId, 0)` to fetch `seq=1, 2` contiguously before persisting, AND hydrates the missing conversation. `_pendingHydrations` is cleared/reconciled by `syncAll()`. |
| **E-5** | **Account switching / logout mid-hydration or mid-message burst** | Late HTTP response from `GET /api/v1/conversations/:id` or late WS frame from Account B writes into Account C's SQLite partition or invalidates Account C's providers. | Every continuation in `ChatSocket` checks `_scopeClosed` (`AccountScope.isOpen`) AND `tokenBefore == _disconnectToken`; `disconnect()` clears `_inFlightHydrations` and `_pendingHydrations`; `ChatDao._guard` checks `scope.isOpen`; `accountScopeProvider` disposal tears down `ChatSocket`, `ChatDao`, `E2eeManager`, and `conversationMetadataProvider`. |
| **E-6** | **User B replies immediately after first contact (E2EE first-reply race)** | `conversationMetadataProvider` hasn't resolved yet and `peerId` is missing -> `E2eeManager.encryptForConversation` silently returns plaintext! | 1. Provisional conversation row sets `peerId: message.senderId`. 2. `ChatScreen` registers `cached.peerId` with `e2eeManager.rememberConversation`. 3. `ChatController.sendText` resolves `peerId` from `dao.conversation(id)?.peerId`, falling back to `api.conversation(id)` if null, and throws `E2eeSendException` if still unknown — never downgrading to plaintext. |
| **E-7** | **Authorization & Privacy Preservation** | Over-broadcasting `conversation_updated` or leaking conversation existence to non-members. | `announce(conversation.id, [request.userId, otherId])` strictly targets the two members created in `conversation_members`. `GET /api/v1/conversations/:id` enforces `requireMemberConversation` (`403 not_a_member`). `ChatGateway.handleSend` enforces `conversations.isMember`. Non-members receive neither `conversation_updated` nor `message` frames. |
| **E-8** | **Message arrives for a newly created Group (user added by non-friend)** | Provisional row defaults `type` to `'direct'` and tries to treat sender as `peerId`. | Backend `message` frame includes `conversation_type: 'group'` and `conversation_name`. Provisional hint sets `type: 'group'`, `name: conversationName`, `peerId: null`, and `_decryptForStorage` sees `isGroup == true` immediately; REST hydration confirms full group metadata and avatar. |

---

## 5. Testing & Real-Device Verification Plan

### 5.1 Backend Automated Tests (Vitest)
Run with: `cd backend && npm run typecheck && npm test`

1. **`backend/test/gateway.test.ts`**
   - *One-way friend DM creation announcement:* Register User A and User B; A adds B as friend (B does NOT add A). Connect User B's WebSocket. User A calls `POST /api/v1/conversations { type: 'direct', member_ids: [B.id] }`. Assert User B immediately receives `{ type: 'conversation_updated', conversation_id }` and User C (unrelated connected outsider) does **not** receive it.
   - *Idempotent re-open does not spam:* User A calls `POST /api/v1/conversations { type: 'direct', member_ids: [B.id] }` a second time; assert no duplicate `conversation_updated` frame is sent.
   - *Enriched live `message` frame:* User A sends a text message in the newly created DM (and in a group); assert User B's `message` frame includes `conversation_type: 'direct'` (or `'group'`), `sender_name`, `sender_avatar_url`, and `conversation_name` (null for direct, group name for group).
2. **`backend/test/friends-and-search.test.ts`**
   - *One-way friendship never blocks conversation/message access:* User A adds User B (B does NOT add A). User A creates DM with B and appends messages. Assert `GET /api/v1/conversations` and `GET /api/v1/conversations/:id` as User B return the conversation with User A's `name`, `nickname`, `avatar_url`, and accurate `unread_count`, while `GET /api/v1/friends` for User B remains `[]`.
3. **`backend/test/messages.test.ts`**
   - *Sync & pagination for non-friend recipient:* Verify User B (without having added User A) can call `GET /api/v1/conversations/:id/sync?after_seq=0` and `GET /api/v1/conversations/:id/messages`, while a non-member User C receives `403`.

### 5.2 Mobile Automated Tests (Flutter)
Run with: `cd mobile && flutter analyze && flutter test`

1. **`mobile/test/chat_dao_test.dart`**
   - *Atomic provisional conversation creation:* Calling `upsertServerMessage` with `ProvisionalConversationHint` and `incrementUnread: true` for an unknown `conversationId` inserts both the `LocalMessages` row and a `LocalConversations` row with `peerId`, `peerName`, `peerAvatarUrl`, `lastSeq`, `lastMessagePreview`, `unreadCount == 1`, and emits on `watchConversations()`.
   - *Live unread increment & idempotency:* Subsequent messages from peer increment `unreadCount` (`1 -> 2 -> 3`); re-upserting an existing `clientMsgId` (duplicate/sync replay) does **not** double-increment `unreadCount`.
   - *Stale REST summary race:* After live WS messages set `lastSeq = 2, unreadCount = 2, preview = 'Hello 2'`, calling `upsertConversation` with a stale server summary (`lastSeq = 0, unreadCount = 0, lastMessage = null`) enriches `peerName`/`peerNickname`/`peerAvatarUrl` while preserving `lastSeq = 2`, `preview = 'Hello 2'`, and `unreadCount = 2`.
2. **`mobile/test/sync_recovery_test.dart`**
   - *Unknown-conversation WS message triggers single-flight hydration under burst:* Deliver 5 rapid WS `message` frames (`seq 1..5`) for an unknown `conversationId` via `handleServerFrameForTesting` while `api.conversation(id)` is gated on a `Completer`. Assert:
     - `watchConversations()` immediately shows the provisional row after `seq 1` (even before the HTTP gate completes!).
     - Only **1** `GET /api/v1/conversations/:id` call is issued across all 5 messages.
     - Once the HTTP gate completes, the conversation row has full server metadata (`peerName`, `peerNickname`, `peerAvatarUrl`), `lastSeq == 5`, `unreadCount == 5`, and decrypted `lastMessagePreview`.
   - *Transient hydration failure retries:* First `api.conversation(id)` throws; provisional row still renders decrypted message; second message (or `syncAll`) retries hydration and enriches metadata.
   - *`conversation_updated` followed by immediate WS messages:* Simulate `conversation_updated` returning `lastSeq: 0` after WS `seq: 1` already arrived; verify unread count and decrypted preview are preserved and `conversationUpdatedEvents` emits.
   - *Account isolation:* Closing `AccountScope` / calling `disconnect()` while hydration is in flight drops the late HTTP response without touching the DB.
3. **`mobile/test/e2ee_delivery_test.dart`**
   - *First-contact E2EE without pre-existing conversation row:* User B has **no** row in `local_conversations` for `'conv-1'` and **no** prior E2EE session with Alice. Alice encrypts messages 1 and 2 (X3DH initiation) and User B receives them via `handleServerFrameForTesting`. Assert both decrypt to plaintext, `local_conversations` is created with decrypted preview and `peerId == 'alice'`, and User B can immediately encrypt a reply to Alice using the established session without plaintext downgrade.
4. **`mobile/test/conversations_screen_test.dart`**
   - *Live emergence of new non-friend DM:* Start with an empty `local_conversations` table (`No conversations yet`). Emit a newly upserted `LocalConversation` (simulating User A's first message arriving while User B is on the Chats tab). Assert the empty state disappears and User A's display name, decrypted preview, and emerald unread badge render immediately without pull-to-refresh.
5. **`mobile/test/chat_screen_test.dart`**
   - *Already-open `ChatScreen` updates live + cached-peer fallback:* Open `ChatScreen` for a direct conversation with `metadata: null` (loading/offline) and cached `peerId: 'alice', peerName: 'Alice'`. Emit live messages on `messagesProvider`; assert bubbles appear immediately, header renders `'Alice'`, and presence watches `'alice'`.
6. **`mobile/test/background_push_decrypt_test.dart`**
   - *Terminated-state first-contact push:* Deliver a `push_schema: "2"` E2EE push for an unknown `conversationId`; assert both `local_messages` (decrypted plaintext) and a provisional `local_conversations` row (`unreadCount: 1`, decrypted preview) are persisted atomically under `.partition.lock`.

### 5.3 Manual 2-Account Verification Checklist (Dev Runtime)

> **Reminder (`AGENTS.MD` Rule 0):** Launch the client using `flutter run -d <device>` against two Android emulators or USB-connected dev devices (never `flutter build apk` or `flutter build appbundle`).

1. **Setup:**
   - Start local stack (`make up && make migrate-up`, REST on `:8080`, Gateway on `:8081`).
   - Register/log in **User A** on Device 1 and **User B** on Device 2.
   - Confirm neither user is in the other's friends list and both have empty Chats lists.
   - On Device 1 (**User A**), search for **User B**, open profile, and tap **Add Friend**.
   - Confirm on Device 2 (**User B**) that **People -> Friends** is still empty (one-way friendship).
2. **Test Case 1 — Conversations List Real-Time Emergence (User B on Chats Tab):**
   - Leave Device 2 (**User B**) open on the **Chats** tab showing *"No conversations yet"*.
   - On Device 1 (**User A**), tap **Message** on User B's profile and send `"Hello from A #1"`.
   - **Expected on Device 2 (without touching screen or refreshing):** Within <1 s, the *"No conversations yet"* screen is replaced by a row showing **User A's display name**, **avatar**, **online presence dot**, decrypted preview **`Hello from A #1`**, timestamp **`now`**, and unread badge **`1`**.
3. **Test Case 2 — Rapid Message Burst:**
   - Still without touching Device 2, send 4 rapid messages from Device 1 (`#2`, `#3`, `#4`, `#5`).
   - **Expected on Device 2:** Preview updates sequentially to `#5`, unread badge increments cleanly to `5`, no duplicates, and no `"Encrypted message"` flicker.
4. **Test Case 3 — Opening Chat & First-Contact Encrypted Reply:**
   - Tap the new chat row on Device 2 (**User B**).
   - **Expected:** All 5 decrypted messages appear in exact order `1..5`; header shows User A's name, avatar, and live `Online` status; Device 1 sees double blue read ticks; navigating back to Chats on Device 2 shows unread badge cleared (`0`).
   - Send a reply `"Hi back from B"` from Device 2.
   - **Expected:** Delivered and decrypted on Device 1 in real time (verify in server logs / DB `messages.content` starts with `e2ee:v1:` — never plaintext).
5. **Test Case 4 — Already-Open ChatScreen (User B Opened via Search):**
   - Repeat with a fresh pair **User C** (adds **User D**) and **User D** (does NOT add **User C**).
   - On Device 2 (**User D**), search for **User C**, open profile, tap **Message** (ChatScreen open, empty).
   - On Device 1 (**User C**), send `"Live while open"`.
   - **Expected on Device 2:** Message bubble appears immediately on the open `ChatScreen` without navigating away; unread badge stays `0`.
6. **Test Case 5 — Other Tab & Brief Reconnect:**
   - Leave **User B** on the **Profile** tab while a new non-friend **User E** messages User B; switch to **Chats** tab -> row, preview, and badge are already present.
   - Toggle airplane mode on Device 2 for 3 s while **User F** (non-friend) creates a DM and sends 2 messages, then restore network -> `syncAll()` recovers the DM and both decrypted messages automatically.
7. **Test Case 6 — Account Isolation Sanity Check:**
   - Log out **User B** on Device 2 and log in as **User G** -> zero conversations or messages from User B appear; live messages sent to User B after logout do not appear in User G's UI.
