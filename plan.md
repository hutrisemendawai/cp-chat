# Plan: Multi-Account Local Data Isolation & Clear-Data Behavior (CPChat)

Status: **planning only** — no application code, config, migration or test is changed by this document.
Scope: Flutter Android client (`mobile/`), with two small optional backend touch-points.
Repo rule 0 (`AGENTS.MD`): **never build an APK/AAB**. Verification uses `flutter analyze`, `flutter test`, and (if backend is touched) `cd backend && npm run typecheck && npm test`.

---

## 1. Requirements

| # | Scenario | Required outcome |
|---|----------|------------------|
| R1 | A logs in → chats → logs out → **B logs in** on the same device | B has **zero** visibility/access to A's conversations, messages, outbox, drafts, cached media, unread counts, local notifications, Riverpod state, WebSocket state, E2EE keys/sessions. |
| R2 | A logs in → logs out → (B logs in/out) → **A logs in again** | A still sees readable history (incl. E2EE messages) and silently syncs messages missed while signed out. |
| R3 | Explicit user intent | Provide an explicit, clearly-worded "remove my data from this device" path, distinct from plain logout. |

R1 and R2 conflict in today's code, which is the core of this plan: either everything is wiped (R2 fails) or everything is shared (R1 fails). The fix is **per-account namespacing of all local state**, not wipe-on-logout.

---

## 2. Current-State Audit (what the code does today)

Findings from reading `mobile/lib` (file references are the authoritative starting points).

| Surface | Today | R1 risk | R2 risk |
|---|---|---|---|
| Drift DB — [`app_database.dart`](mobile/lib/core/database/app_database.dart) | One global file `driftDatabase(name: 'cp_chat')`; tables `LocalConversations`, `LocalMessages`, `OutboxEntries` have **no owner column**. `schemaVersion = 5`. | Any leftover row (or late async write) is visible to the next user. | — |
| Logout — `AuthController.logout()` in [`providers.dart`](mobile/lib/core/providers.dart) | Calls `chatDao.clearAll()` (wipes conversations, messages, **outbox**). Steps have 5 s timeouts; on timeout the work **continues in the background**. | A timed-out `clearAll`/sync can race with B's login and write/delete in the shared DB. | **Wipes A's history.** Because E2EE uses forward-secret ratchets, A's old ciphertext cannot be re-decrypted from the server → history is permanently unreadable after re-login. Unsent outbox also lost. |
| E2EE keys/sessions — [`token_store.dart`](mobile/lib/core/storage/token_store.dart) | Secure-storage keys `e2ee_keys`, `e2ee_sessions` are **device-global**, not user-scoped; `clear()` intentionally keeps them. Sessions are keyed only by `peerId`. | **Critical:** B bootstraps with A's identity/signed-prekey/ratchets and `_publish`es A's key material as B's server identity (server stores one identity per `user_id`, [`keys.ts`](backend/src/domain/keys.ts)). B could decrypt A's in-flight messages; peers would encrypt to a key B shouldn't hold. | Keys survive, so R2 *would* work for keys — but the sessions are also overwritten/mixed by B's activity. |
| `E2eeManager.reset()` — [`e2ee_manager.dart`](mobile/lib/core/crypto/e2ee_manager.dart) | Clears in-memory plaintext cache, peer map, service sessions. Good, but `readUserId()` is read from storage at decrypt time. | Race if a decrypt is in flight during switch (uses whichever user id is in storage at that instant). | — |
| Riverpod graph — [`providers.dart`](mobile/lib/core/providers.dart) | `appDatabaseProvider`, `chatDaoProvider`, `tokenStoreProvider`, `e2eeManagerProvider`, `chatSocketProvider`, `messageNotifierProvider`, `mediaServiceProvider` are **process-lifetime singletons**. `apiClientProvider` watches only `deviceIdProvider`, not the account. Only the explicit `logout()` resets a few things (`activeConversationIdProvider`, E2EE manager). | Anything not explicitly reset survives user switch (family/autoDispose caches such as `presenceProvider`, `userProfileProvider`, `conversationMetadataProvider`, `friendsProvider`, `peopleControllerProvider`, `groupControllerProvider`, `chatSocket` presence maps, `messageNotifier` dedupe state). | — |
| WebSocket — [`ws_client.dart`](mobile/lib/core/network/ws_client.dart) | One `ChatSocket` bound to the singleton DAO/API; `disconnect()` on logout; per-conversation sync cursor = `localConversations.lastSeq`. | In-flight frames/syncs/outbox flushes can persist into the *next* account's DB (no account epoch check). | Cursor lives in the DB; wiping it forces full resync (and unreadable E2EE history). |
| Local notifications — [`local_notification_service.dart`](mobile/lib/core/notifications/local_notification_service.dart), [`fcm_service.dart`](mobile/lib/core/notifications/fcm_service.dart) | `cancelAll()` on logout; payload is bare `conversationId`. Headless FCM isolate shows any data-only push with **no account check**; unregister is best-effort (needs network). | If unregister fails offline, A's pushes still display while B is signed in (or before anyone is); tapping routes `conversationId` into B's session. | — |
| Media cache — [`media_message.dart`](mobile/lib/features/chat/media_message.dart), [`media_service.dart`](mobile/lib/core/media/media_service.dart) | `CachedNetworkImage` uses the **shared default cache manager** (keyed by URL, on disk); Flutter's in-memory `ImageCache` is process-wide; compressed uploads written to `getTemporaryDirectory()`. | B can be served A's cached bytes (disk + memory) for the same URL; temp files linger. | — |
| Drafts | No persisted drafts. Text controllers are widget-local (`chat_screen`, `search_screen`, `conversations_screen`, …). | Only if a route/widget is retained across account switch (navigator stack not reset, controllers hoisted into providers later). | Drafts are not retained across logout (nice-to-have for R2). |
| Token/session — `TokenStore`, `hydrateAuthState` | Tokens + `user_id` + cached `user_profile` cleared on logout. `device_id` intentionally device-global. | OK as designed. | OK. |
| Backend | `device_tokens(user_id, device_id, fcm_token)`; `registerToken` already steals a token from other users ([`devices.ts`](backend/src/domain/devices.ts)). `user_identity_keys` is **one row per user** (single-device E2EE). | Mitigates stale-token pushes only after B registers. | **Limitation:** if A re-installs/signs in on a *second* device and republishes, this device's local keys no longer match the server (pre-existing multi-device gap; see §10). |

---

## 3. Design Principles

1. **Namespace, don't wipe.** Every piece of per-user local state is addressed by an opaque `AccountId` (derived from the server `user.id`). Logout *closes* the namespace; login *opens* one. Wiping is a separate, explicit operation.
2. **Isolation by construction, not by cleanup.** The next account must be *unable* to reach the previous namespace (different DB file, different secure-storage keys, different cache dir) even if a cleanup step fails or times out.
3. **One owner for the active account.** A single `activeAccountIdProvider` is the root of dependency for all user-bound providers; changing it tears down the whole user-bound graph.
4. **Stale async work must be harmless.** Anything started under account A that completes after A's scope closed must fail closed (writes dropped), never land in B's state.
5. **Never block sign-out on the network.** Local teardown completes deterministically; server calls are best-effort and the app is safe even if they never happen.
6. **Defense in depth.** File/key namespacing + ownership assertions in the DB + notification payload account check + tests that enforce the rules.

---

## 4. Target Architecture

### 4.1 Account identity & registry

- `AccountId`: `sha256(userId)` truncated to 16 hex chars (`a3f9…`). Used for file names and storage keys so raw ids/PII do not appear on disk paths.
- `AccountRegistry` (new, `core/account/account_registry.dart`): stored in secure storage under `accounts_index` (JSON list of `{accountId, userId, lastActiveAt}`), plus `active_account_id`. Responsibilities: register on first login, record `lastActiveAt`, enumerate known accounts, delete an account entry on explicit wipe.
- `AccountPaths` (new): pure functions mapping `AccountId` →
  - DB file: `<appSupportDir>/accounts/<id>/chat.sqlite`
  - Media cache dir: `<appSupportDir>/accounts/<id>/media_cache/`
  - Secure-storage key prefix: `acct.<id>.`
- Secure storage layout (all via a new `AccountStore` wrapper, never raw `FlutterSecureStorage` outside `core/storage`):

| Key | Scope |
|---|---|
| `device_id` | device-global (routing; unchanged) |
| `access_token`, `refresh_token`, `user_id`, `user_profile` | **current session only**, cleared on logout (unchanged semantics) |
| `active_account_id`, `accounts_index` | device-global registry |
| `acct.<id>.e2ee_keys`, `acct.<id>.e2ee_sessions` | **per account**, survive logout (R2) |
| `acct.<id>.db_key` *(Phase 6 hardening)* | per account |

### 4.2 Account-scoped provider graph

```
authControllerProvider ──► currentUserIdProvider (select user.id; token rotation does NOT rebuild)
                               │
                               ▼
                    accountScopeProvider  (AccountScope | null)
        { accountId, userId, epoch, paths, closed: Completer }
                               │ watched by every user-bound provider
   ┌────────────┬──────────────┼───────────────┬──────────────┬───────────────┐
   ▼            ▼              ▼               ▼              ▼               ▼
appDatabase  accountStore   apiClient     e2eeManager    mediaCache      localNotifications
   │                           │               │          (CacheManager)   (account-tagged)
 chatDao                       └──► chatSocket ◄┘
   │                                 │
conversations/messages        messageNotifier, presence, people, groups, metadata …
```

Rules:
- `accountScopeProvider` is a plain `Provider<AccountScope?>` that `ref.watch`es `currentUserIdProvider`. When the id changes (A→null→B) Riverpod disposes everything that watched it; `ref.onDispose` closes DB, disposes socket, resets E2EE manager, disposes the cache manager.
- Every user-bound provider (`appDatabaseProvider`, `chatDaoProvider`, `apiClientProvider`, `e2eeManagerProvider`, `chatSocketProvider`, `messageNotifierProvider`, `mediaServiceProvider`, `pushRegistrationProvider`, `presenceProvider`, `friendsProvider`, `userProfileProvider`, `conversationMetadataProvider`, `peopleControllerProvider`, `groupControllerProvider`, `conversationsProvider`, `messagesProvider`, `accessTokenProvider`) must `ref.watch(accountScopeProvider)` (directly or transitively). Add a short "scoping rule" doc comment at the top of `providers.dart` and a test (§8) that enforces it.
- Device-global providers stay global: `deviceIdProvider`, `appLoggerProvider`, `appLifecycleProvider`, `bootstrapProvider`, theme.
- `activeConversationIdProvider` becomes scoped (resets automatically).
- Logging: `AppLogger` ring buffer is cleared on account change (diagnostics can contain ids/preview metadata).

### 4.3 Per-account database

- `AppDatabase(AccountPaths paths)` opens `chat.sqlite` for that account only (drift `NativeDatabase.createInBackground(File)`), replacing the shared `cp_chat`.
- **Ownership assertion (defense in depth):** schema v6 adds `account_meta(key TEXT PK, value TEXT)`; on open, write `owner_user_id` if empty, otherwise assert it equals the scope's `userId`. A mismatch → close, delete the file, recreate (should be unreachable; logs a `warn`).
- Schema v6 also adds `drafts(conversation_id PK, body TEXT, updated_at)` (optional, Phase 5) so drafts persist per account (R2 nice-to-have) and are physically unreachable to B.
- `ChatDao.clearAll()` is retained but **no longer called by logout**; it is used only by "Clear chat cache" (§6).
- Migration `from < 6` creates `account_meta` and `drafts`. Existing tables are unchanged (no owner column needed: file-level isolation).
- The `UNIQUE (conversation_id, seq)` constraint and `lastSeq` cursor stay per account, so re-login resumes `GET sync?after_seq=lastSeq` seamlessly (R2).

### 4.4 Per-account E2EE

- `E2eeManager` takes an `AccountStore` (scoped) instead of `TokenStore`; reads/writes `acct.<id>.e2ee_keys|sessions`. `selfId` comes from `AccountScope.userId`, not `readUserId()` at call time.
- `bootstrap()` flow for account X:
  1. Load `acct.X.e2ee_keys`; if present, import + restore sessions + replenish OTPs (existing behavior).
  2. If absent, generate + persist + publish (existing behavior) — **only ever for X**, so B can never publish A's keys.
  3. *Re-login reconcile (new):* compare the local identity public key with the server's published identity for X (via a non-consuming read — see §7). Match → continue. Mismatch → log, flag `e2eeKeyMismatch` in session state; do **not** silently overwrite local keys (preserves ability to read old local history); decide republish policy per open question Q3.
- Persistence safety: `_persistSessions()` must complete before the account scope closes (logout awaits an `E2eeManager.flush()`); otherwise a ratchet advance could be lost and A's next-session decryption break.
- In-memory: `reset()` also drops pending decrypt queue; decrypt calls check `scope.isClosed` before writing plaintext/sessions.

### 4.5 Per-account media cache

- Replace implicit `DefaultCacheManager` with `AccountMediaCache` = `CacheManager(Config('media_<id>', stalePeriod: …, maxNrOfCacheObjects: …, repo: JsonCacheInfoRepository(path), fileSystem: IOFileSystem(<accountDir>/media_cache)))`.
- `CachedNetworkImage(cacheManager: ref.watch(mediaCacheProvider), cacheKey: '<id>:$objectKey')` in `media_message.dart` and avatar widgets (`user_avatar.dart`, `status_*`, `group_info`, `my_profile`).
- On scope close: `cacheManager.dispose()`; on account switch also `PaintingBinding.instance.imageCache..clear()..clearLiveImages()` (process-wide, in-memory).
- Upload temp files (`MediaService._compressImage`) go to `<accountDir>/tmp/`; `_deleteQuietly` after upload (already exists for the compressed copy), and the account tmp dir is emptied on scope close.
- Startup janitor: delete `getTemporaryDirectory()` leftovers and any `accounts/<id>/` directory **not** present in `AccountRegistry` (orphans from interrupted wipes).

### 4.6 Per-account WebSocket / sync

- `ChatSocket` constructed per scope, receives `AccountScope`. Every async continuation (`_handleMessage`, `_persistServerMessage`, `_syncConversation`, outbox flush, decrypt) captures `scope.epoch` at entry and checks `scope.isOpen` before touching DB/state; otherwise drops silently.
- `disconnect()` (a) stops reconnect timers, (b) cancels in-flight syncs via a cancel token, (c) awaits the sync barrier with timeout, (d) closes the channel with a normal close code.
- Connection registry on the server is keyed by user+device; the socket is authenticated with the new account's token only after the old socket's `disconnect()` future has completed. Gate `SessionLifecycle.start()` on the previous `stop()` future (`_stopping`) to prevent overlap on rapid A→B login.
- Outbox: rows belong to A's DB, so only A's socket can flush them. They persist across logout and flush on A's next login (idempotent by `client_msg_id`). Add `OutboxEntries.createdAt`-based expiry (e.g. mark `failed` after 7 days) to avoid ancient sends.

### 4.7 Notifications (local + push)

- All local notifications carry a JSON payload `{"a":"<accountId>","c":"<conversationId>"}`; notification ids hash `(accountId, conversationId)`.
- `LocalNotificationService`: `cancelAllForAccount(accountId)` (use Android notification **group/tag = accountId**; `cancelAll()` only as a fallback). Tap routing ignores payloads whose `a` ≠ active account (and drops them, shows nothing).
- Headless FCM handler (`firebaseMessagingBackgroundHandler`): read `active_account_id` from secure storage; **drop** the push unless its `recipient_user_id` (new payload field, §7) hashes to the active account **and** a session exists. With no session (A logged out, nobody logged in) show nothing — do not leak "New message" for a signed-out account.
- Logout: best-effort `unregisterFcmToken()` (kept) + cancel account notifications + reset `MessageNotifier` dedupe state (scoped provider).
- Unread counts: live in the per-account DB; app-icon badge (if added) must be derived from the active account only.

### 4.8 UI / navigation state

- On account change, the router performs `go('/auth')` (already via redirect) **and** the root navigator is keyed by `accountId` (`KeyedSubtree`/`ValueKey`) so no widget/State/TextEditingController survives. Screens that hold per-account state in `State` need no extra work once the subtree is rebuilt.
- Persisted drafts (if Phase 5 ships) are read through `draftsProvider(conversationId)` (account-scoped).

### 4.9 Logout / login sequences

**Logout (R1 + R2) — local part is deterministic and network-independent**

```
1. UI: show "Signing out…" (non-dismissible), block new sends
2. scope.beginClose()            // epoch++; async work now fails closed
3. socket.disconnect()           // bounded, 3 s
4. e2ee.flush()                  // persist ratchets; bounded, 3 s
5. notifications.cancelForAccount(accountId); notifier.reset()
6. push.unregister() + api.logout()   // best-effort, parallel, bounded, errors logged only
7. close DB / dispose cache manager / clear image caches / empty tmp
8. tokenStore.clear()            // tokens, user_id, user_profile only
9. registry.setActive(null) → authState = unauthenticated → graph disposes → router → /auth
```
Never calls `chatDao.clearAll()` or `clearE2ee()`. If any step 3–7 times out, namespacing still guarantees B cannot reach A's data (late writes hit A's closed/own DB file).

**Login as X (including re-login)**

```
1. api.login → session (token, user)
2. registry.register(X) (idempotent); setActive(X); tokenStore.saveSession/saveUser
3. authState = authenticated(X) → accountScope(X) created → providers build lazily
4. SessionLifecycle.start(): await previous stop(); e2ee.bootstrap(); socket.connect() → syncAll()
5. syncAll uses X's lastSeq cursors → missed messages fetched in order; E2EE decrypted via X's restored sessions (R2)
6. flush X's outbox; request notification permission; register push
```

**Cold start** — `hydrateAuthState` reads tokens + `active_account_id`; if tokens exist but registry/active id is missing or disagrees with the stored `user_id`, treat as signed out (fail closed) and run the janitor.

### 4.10 Clear-data behavior matrix

| Action | Trigger | DB | E2EE keys/sessions | Media cache | Tokens | Notifications | Server |
|---|---|---|---|---|---|---|---|
| **Logout** (default) | Profile → Log out | kept (closed) | kept | kept (closed) | cleared | account's cleared | token revoked, push unregistered (best-effort) |
| **Clear chat cache** | Settings → Storage (signed in) | `clearAll()` on *active* account only; cursors reset | kept (new messages still decrypt; old E2EE history shows as `undecryptableContent` — warn the user) | emptied | kept | kept | none |
| **Log out & remove data from this device** | Logout dialog checkbox / Settings | file deleted | deleted | deleted | cleared | cleared | + `unregister`; keys on server untouched (user must treat as new-device key reset on next login) |
| **Remove other account's data** | Settings → "Accounts on this device" (optional) | deleted via registry | deleted | deleted | n/a | n/a | n/a |
| **Forced sign-out** (401/403 on validate) | server revocation | same as Logout (data retained) | kept | kept | cleared | cleared | n/a |
| **Uninstall / Android "Clear storage"** | OS | all gone | all gone | all gone | all gone | — | server keys orphaned → relogin generates new keys (existing behavior) |

Wipe is implemented once as `AccountWiper.wipe(accountId)` (idempotent, resumable: writes `wipe_pending.<id>` marker first; janitor completes it on next launch).

---

## 5. Legacy Migration (existing installs)

Existing installs have one global DB `cp_chat` and global `e2ee_*` keys with **no owner marker**.

1. On first launch of the new build (`schema/layout version` marker in secure storage `local_layout=2`):
   - **A session exists** (tokens + `user_id`): the legacy data belongs to that user (legacy logout wiped the DB, and keys were only ever used by sessions on this device — see Q2 for the key edge case). Move/rename `cp_chat.sqlite` → `accounts/<id>/chat.sqlite`; copy `e2ee_keys/sessions` → `acct.<id>.*`; run drift migration to v6.
   - **No session**: legacy DB is empty by construction (old logout cleared it); delete it. Legacy E2EE keys are ownerless → delete them (a one-time key regeneration on next login; safe because the identity is republished). Alternative to avoid losing keys: verify ownership against the server identity on first login (Q2).
2. Delete legacy global keys after a successful copy; write `local_layout=2`. Migration is idempotent and crash-safe (copy → verify → mark → delete).
3. Unit-test the migration with fake secure storage and temp directories.

---

## 6. Phased Implementation

Each phase is independently shippable/mergeable, ends green on `flutter analyze` + `flutter test`, and never builds an APK.

### Phase 0 — Characterization & safety net (no behavior change)
- Add failing/skipped tests documenting R1/R2 (see §8) so progress is measurable.
- Add `test/support/fake_secure_storage.dart` and temp-dir DB helpers (extend `test/support/factories.dart`).
- Deliverable: red tests tagged `account_isolation`.

### Phase 1 — Account identity & storage foundation
- New: `core/account/{account_id.dart, account_paths.dart, account_registry.dart, account_store.dart, account_scope.dart}`.
- `TokenStore`: keep session keys; move E2EE accessors behind `AccountStore(accountId)`; keep `TokenStore.readE2ee*` temporarily as deprecated legacy readers for migration only.
- `currentUserIdProvider`, `accountScopeProvider`; `AccountScope` with `epoch`, `isOpen`, `beginClose()`, `onClosed`.
- Legacy migration (§5) + janitor skeleton.
- Tests: id derivation, registry CRUD, migration cases (session / no session / crash mid-copy).

### Phase 2 — Per-account database & logout contract
- `AppDatabase(AccountPaths)`, schema v6 (`account_meta`, `drafts`), owner assertion, `appDatabaseProvider`/`chatDaoProvider` scoped.
- Rewrite `AuthController.logout()` per §4.9 (remove `clearAll`, add ordered bounded steps, `scope.beginClose()`).
- Update `conversationsProvider`/`messagesProvider` to handle "no scope".
- Tests: A writes → logout → B sees empty DB; A re-login sees A's rows; late write after `beginClose` is dropped; `chat_dao_test` updated.

### Phase 3 — Per-account E2EE
- `E2eeManager` → `AccountStore`, explicit `selfId`, `flush()`, closed-scope guards; `e2eeManagerProvider` scoped.
- Bootstrap reconcile with server identity (needs §7 backend read or an equivalent check).
- Tests (extend `e2ee_manager_test`, `e2ee_delivery_test`): B bootstrap never loads A's keys; B publishes a *different* identity; A re-login decrypts a message that was sent while A was signed out (ratchet continuity after B interleaved); sessions for the same peer id under A and B stay separate.

### Phase 4 — Scoped network stack (API, WebSocket, Riverpod graph)
- `apiClientProvider` watches `accountScopeProvider`; per-account token/refresh handling; `chatSocketProvider`, `messageNotifierProvider`, `presenceProvider`, `friendsProvider`, `userProfileProvider`, `conversationMetadataProvider`, `peopleControllerProvider`, `groupControllerProvider`, `activeConversationIdProvider`, `pushRegistrationProvider` scoped.
- Epoch/cancellation checks in `ChatSocket`; `SessionLifecycle.start()` awaits the prior `stop()`.
- Clear `AppLogger` buffer on account change.
- Tests: `session_runtime_test` (rapid A→B), `sync_recovery_test` (cursor per account), `cold_start_test`, presence/people caches empty for B.
- Add the provider-scoping guard test (§8).

### Phase 5 — Media cache, notifications, drafts, UI reset
- `AccountMediaCache` + `CachedNetworkImage` wiring; image-cache clearing; tmp dir relocation & janitor.
- Notification payload `{a,c}`, per-account cancel/group, tap routing guard, headless handler account check.
- Persisted drafts via `drafts` table (chat input saves on debounce; cleared on send).
- Keyed root navigator; verify no `TextEditingController` state leaks (widget tests).
- Tests: `notifications_test` (foreign-account payload dropped), `media_and_receipts_test` (cache manager is per account), `chat_screen_test` (draft restore for A, absent for B).

### Phase 6 — Clear-data UX & hardening
- Logout dialog with "Also remove my data from this device" (+ plain-language E2EE warning), Settings → Storage ("Clear chat cache"), optional "Accounts on this device".
- `AccountWiper` (idempotent/resumable) + janitor completion of pending wipes.
- *Optional hardening:* SQLCipher (`sqlcipher_flutter_libs`) with a random per-account key stored at `acct.<id>.db_key`, so a closed account's DB is unreadable without Keystore access; wipe = delete key + file. Evaluate APK-size/perf impact first (Q4).
- Retention policy for inactive accounts (Q5).
- Tests: wipe is complete and idempotent (kill-mid-wipe resumes), clear-cache keeps keys.

### Phase 7 — Backend touch-points, docs, rollout
- Backend (small): FCM payload adds `recipient_user_id`; optional `GET /keys/me/identity` (non-consuming). Update `api-spec.yaml`, backend tests (`notifications.test.ts`, `keys.test.ts`). Skip if Q3/Q6 decide otherwise.
- Docs: update `docs/e2ee.md`, `docs/architecture.md` (local data model & account scoping), `README` troubleshooting.
- Rollout: staged release; log (non-PII) counters for migration outcome (`legacy_adopted`, `legacy_discarded`), owner-assertion failures, and mismatch events through `AppLogger`.

Suggested sequencing: 0 → 1 → 2 → 3 → 4 (the isolation/continuity core, ship together as one release train) → 5 → 6 → 7.

---

## 7. Backend Changes (small, optional but recommended)

| Change | Why | Risk |
|---|---|---|
| Add `recipient_user_id` to FCM `data` payload in `backend/src/lib/fcm.ts` / notification path | Lets the headless handler drop pushes for non-active accounts without a session. | Additive; older clients ignore it. |
| Non-consuming "get my published identity" endpoint (`GET /keys/me`), or reuse an existing read that does not burn a one-time prekey | Re-login key-reconciliation (Phase 3) and legacy-key ownership check (Q2). | Must not consume OTPs. Verify `key-routes.ts` before adding. |
| (Existing) `registerToken` already reassigns an FCM token away from other users | No change; document it as the server-side backstop. | — |

No DB migration is required on the backend.

---

## 8. Test Strategy

New suite `mobile/test/account_isolation_test.dart` (+ helpers), run with temp dirs and a fake secure storage:

1. **R1 end-to-end (provider level):** ProviderScope with auth controller; A logs in, seed conversations/messages/outbox/unread/drafts; logout; B logs in → every list provider empty, `activeConversationId` null, no notifications scheduled (fake service records cancels), `chatSocket` has no A state, `e2eeManager.isReady` only after B bootstrap with different keys.
2. **R2:** A logs in, receives E2EE message, logs out; B logs in, sends/receives, logs out; A logs in → history readable from DB without network; fake API serves 2 missed E2EE messages → decrypted in order, `lastSeq` advanced, outbox flushed once.
3. **Stale async:** start a sync/decrypt under A, `beginClose()`, log in B, release the sync → B's DB unchanged, no exceptions surface.
4. **Logout robustness:** stalled socket / failing `api.logout` / failing unregister → state still unauthenticated, data namespaces intact, tokens cleared.
5. **Legacy migration matrix** (§5).
6. **Wipe/clear:** remove-data deletes DB file + keys + cache dir; clear-cache keeps keys; resumable after simulated crash.
7. **Notification guards:** foreign-account payload dropped in handler and in tap routing.
8. **Static guard tests** (cheap CI lint-by-test): grep `mobile/lib` and fail on `FlutterSecureStorage(` outside `core/storage`, `DefaultCacheManager`, `getTemporaryDirectory` outside the account tmp helper, `driftDatabase(name:` outside `AccountPaths`, and verify each provider in a registered `accountScopedProviders` list is disposed when `accountScopeProvider` changes.
9. Update existing: `session_runtime_test`, `chat_dao_test`, `e2ee_manager_test`, `e2ee_delivery_test`, `notifications_test`, `cold_start_test`, `sync_recovery_test`, `media_and_receipts_test`.

Gates per phase: `cd mobile && flutter analyze && flutter test`; backend phase adds `cd backend && npm run typecheck && npm test`. **No APK/AAB build.**

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Forgetting to scope one provider re-introduces a leak | Provider-scoping registry + guard test; doc rule in `providers.dart`; PR checklist. |
| Provider disposal while async work is mid-flight throws "database closed" | Epoch checks + `try/catch` on closed-DB errors in DAO callers; logout orders socket stop → flush → close. |
| Losing ratchet state on abrupt close | `E2eeManager.flush()` awaited in logout; sessions persisted after every advance (existing). |
| Legacy key ownership ambiguity | Adopt only for the live session; otherwise discard or verify against server identity (Q2). |
| Data remaining on disk after logout is a privacy trade-off | Documented; explicit remove-data path; optional SQLCipher with Keystore-held per-account key (Phase 6). Threat model: other app *users/accounts*, not a rooted/forensic attacker. |
| Disk growth with many accounts | Retention policy + "Accounts on this device" management (Q5). |
| Late/duplicate pushes after logout offline | Account-checked headless handler + server token reassignment on next login. |
| Rapid A→B switch races | `start()` awaits previous `stop()`; scope epoch; single active-account pointer. |

---

## 10. Out of Scope / Known Limitations

- **True multi-device E2EE** for one user (server stores one identity per user). If A signs in on another device and republishes keys, this device's local keys diverge from the server; Phase 3 reconcile detects and surfaces it but does not solve it.
- Simultaneous multi-account (account switcher with two live sessions). The design (scoped providers) makes this a later extension, but this plan delivers **sequential** accounts only.
- Group E2EE (groups are plaintext today).
- Server-side data deletion.

---

## 11. Open Questions (need product/tech decision)

1. **Default logout retention:** keep data (as designed, needed for R2) — confirm there is no compliance requirement to wipe by default on shared devices.
2. **Legacy E2EE keys with no session at upgrade:** discard (simple, causes one-time loss of old E2EE readability) vs verify ownership against server identity at next login (needs `GET /keys/me`).
3. **Key mismatch on re-login:** keep local keys and warn, or republish local keys, or reset? (Impacts peers' sessions.)
4. **At-rest encryption (SQLCipher):** required now, or acceptable as a follow-up?
5. **Inactive-account retention:** never auto-delete, or evict after N days (E2EE history then lost)?
6. **Backend change window:** OK to add `recipient_user_id` to push and a key-identity read endpoint?
7. **Outbox expiry:** is 7 days the right cutoff for unsent messages after long logouts?

---

## 12. Definition of Done

- R1 and R2 scenarios pass in automated tests (provider-level) and a documented manual two-account emulator checklist (including offline logout, rapid A→B switch, killed-app mid-logout).
- No user-bound provider, cache, file, or secure-storage key exists outside the account namespace (enforced by guard tests).
- Logout never deletes data; explicit wipe deletes everything for that account and is idempotent.
- Legacy installs upgrade without cross-user exposure.
- `flutter analyze`, `flutter test` (and backend typecheck/tests when touched) are green; docs updated; no APK built.
