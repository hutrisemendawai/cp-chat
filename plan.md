# Plan: Multi-Account Isolation & Full-Wipe Clear-Data (CPChat)

Status: **planning only**. This document is the only deliverable; no application source, config, migration or test is changed by it.
Repo rule 0 (`AGENTS.MD`): **never build an APK/AAB**. Verification = `cd mobile && flutter analyze && flutter test`, plus `cd backend && npm run typecheck && npm test` when backend code is touched. Manual QA (§5.2) runs on builds produced by the owner/release pipeline, not by agents.
Revision note: this revision supersedes the earlier plan. It corrects two earlier assumptions: (1) `GET /api/v1/keys/me` **already exists**, so no new key-read endpoint is needed; (2) Android backup is **already disabled** in the manifest, but with gaps (§1.7).

---

## 0. Requirements

| # | Scenario | Required outcome |
|---|---|---|
| R1 | A → logout → **B** logs in (same device) | B sees nothing of A: conversations, messages, outbox, drafts, media cache, unread counts, notifications, Riverpod state, WebSocket state, E2EE keys/sessions. |
| R2 | A → logout → (B in/out) → **A** logs in | A sees her readable history (incl. E2EE) and silently syncs what she missed. |
| R3 | **Clear Data** (OS *and* in-app) | All chat history is really gone: not restored by Android Auto Backup / device transfer, and **not** re-synced from the server as undecryptable "Unable to decrypt this message" stubs after re-login. |

R1+R2 are solved by **per-account local partitions** (namespace, don't wipe). R3 needs **three layers**: (a) no OS backup path, (b) a clean local reset, (c) a **server-side history watermark** so the server stops serving history that the client deliberately dropped or can no longer decrypt.

---

## 1. Current State Audit (exact references)

Line numbers are from the current `main` (HEAD `f50aa87`+). `mobile/lib/...` abbreviated as `lib/...`.

### 1.1 Local storage, DB, lifecycle

| Finding | Where |
|---|---|
| Single shared SQLite file, name `cp_chat`, no owner column in any table; `schemaVersion = 5`. | `lib/core/database/app_database.dart:86` (`driftDatabase(name: 'cp_chat')`), `:91`; tables `:7-80` |
| DB provider is a **process-lifetime singleton** (not tied to the user); DAO likewise. Closed only when the whole `ProviderScope` dies. | `lib/core/providers.dart:22-30` |
| `beforeOpen` sets only `PRAGMA foreign_keys`; comment mentions WAL but none is configured, no `busy_timeout`. | `app_database.dart:~118-123` |
| `ChatDao.clearAll()` deletes outbox, messages, conversations (all rows, no user filter). | `lib/core/database/chat_dao.dart:549-556` |
| Tokens/`user_id`/`user_profile` in secure storage; `device_id` is device-global and survives logout; E2EE keys/sessions are **global keys** `e2ee_keys`, `e2ee_sessions`. `clear()` intentionally keeps device id + E2EE. | `lib/core/storage/token_store.dart:13-19`, `:71-76` (clear), `:92-95` (`clearE2ee`, unused by logout) |
| Cold start reads tokens only (`hydrateAuthState`), seeds `AuthController` before `runApp`. | `lib/main.dart:45-55`, `lib/core/providers.dart:379-402` |

### 1.2 Provider graph & session lifecycle

| Finding | Where |
|---|---|
| `apiClientProvider` watches only `deviceIdProvider` – it is **not** keyed to the account. `tokenStoreProvider`, `e2eeManagerProvider`, `chatSocketProvider`, `messageNotifierProvider`, `mediaServiceProvider`, `pushRegistrationProvider` are singletons that survive an account change. Autodispose/family caches (`presenceProvider`, `friendsProvider`, `userProfileProvider`, `conversationMetadataProvider`, `peopleControllerProvider`, `groupControllerProvider`) are not invalidated on logout. | `providers.dart:32-135`, `:144-175`; `features/presence/presence_controller.dart:19,55`; `features/people/people_controller.dart:11,17,193`; `features/chat/conversation_metadata.dart:8` |
| `SessionLifecycle.start()/stop()` only handles E2EE bootstrap, socket, push; `stop()` ends with `e2eeManagerProvider.reset()` (memory only). | `providers.dart:231-329` (`_start` `:261`, `_stop` `:307`, reset `:327`) |
| `SessionRuntime` listens to auth state → `start()` / `stop()`. | `providers.dart:337-357` |

### 1.3 What happens today, per scenario

| Scenario | Current behavior | Problem |
|---|---|---|
| **Logout** (`my_profile_screen.dart:181` → `AuthController.logout`, `providers.dart:491-537`) | Steps, each capped at `logoutStepTimeout = 5 s`: `SessionLifecycle.stop()` → `pushRegistration.unregister()` → `api.logout()` → **`chatDao.clearAll()` (`:515`)** → `cancelAll()` notifications (`:522`) → `activeConversationId.reset()` → `tokenStore.clear()` (`:532`) → `state = unauthenticated`. A step that overruns its timeout is abandoned but **keeps running**. | History is **wiped on every logout** → R2 fails (E2EE history cannot be re-decrypted: forward-secret ratchet). Unsent outbox lost. Late work from a stalled step can touch the shared DB after B logs in. |
| **Login as other user B** (`auth_screen.dart:57,64` → `login()` `providers.dart:416`) | Same DB file, same global E2EE keys/sessions, same singletons. | E2EE: `bootstrap()` (`e2ee_manager.dart:102-116`) loads **A's** identity/ratchets from global storage (`:105`) and `_publish`es them as **B's** server identity (`:378`; server upsert `keys.ts:85-114`). Cross-user key sharing = critical R1 break. Residual DB rows or in-flight writes visible to B. |
| **Re-login as same user A** | Keys survive (good), DB was wiped (bad), sync restarts at cursor 0 (`ws_client.dart:240-267`, `:338-348`). | Server ciphertext re-fetched; ratchet already advanced → every old E2EE message renders as stub: `undecryptableContent = 'Unable to decrypt this message'` (`e2ee_service.dart:886`, `e2ee_manager.dart:165,184`, `chat_screen.dart:709-711`). |
| **OS Clear Data** | Wipes app data dir **and** Keystore entries: DB, tokens, `device_id`, E2EE keys, sessions all gone; FCM instance id regenerates. Server still holds: old `user_identity_keys`/prekeys, old `refresh_tokens`, old `device_tokens(user_id, device_id, fcm_token)`, and **all** messages. | On re-login: new `device_id`; `bootstrap()` generates fresh keys (`:111-114`) → server sees a *different* identity → deletes OTPs (`keys.ts:106-109`, doc `docs/e2ee.md:38`). `syncAll` pulls the full history again (`ws_client.dart:250-267`) → hundreds of "Unable to decrypt" stubs; peers' next messages (ratchet continuation, no `ek`) are also undecryptable until a new session is initiated (`docs/e2ee.md:97-98,103-123`). Old device token row is stale until FCM prunes it (`fcm.ts:27-28,139`). |

### 1.4 WebSocket / sync / caches

| Finding | Where |
|---|---|
| One `ChatSocket` bound to singleton DAO/API; `disconnect()` at `:197`. Sync cursor = local `localConversations.lastSeq`; `syncAll()` lists up to 100 conversations (`:250`) and `_syncConversation` pages `api.sync(afterSeq: cursor)` (`:338-348`). **No account epoch check**: frames, syncs, outbox flushes (`:493`), decrypt-for-storage (`:687`) persist into whatever DB is current. | `lib/core/network/ws_client.dart` |
| E2EE manager reads `selfId` from storage at decrypt time, not from a bound scope. | `e2ee_manager.dart:171` |
| Media: `CachedNetworkImage` uses the **shared default cache manager** (disk, keyed by URL); Flutter in-memory `ImageCache` is process-wide; compressed uploads written to `getTemporaryDirectory()`. | `features/chat/media_message.dart:52,89`; `core/media/media_service.dart:100` |
| Drafts: not persisted; text controllers are widget-local. | `chat_screen.dart`, `search_screen.dart`, `conversations_screen.dart` |

### 1.5 Notifications

| Finding | Where |
|---|---|
| Local notification payload is a bare `conversationId`; no account tag. `cancelAll()` only called from logout. Cold-start tap payload stored in `_coldStartConversationId` without account check. | `lib/core/notifications/local_notification_service.dart:73-75,115,126` |
| Headless FCM handler shows any data-only push with no session/account check; `getInitialMessage` / `onMessageOpenedApp` routed without account check. FCM unregister is best-effort and needs network. | `lib/core/notifications/fcm_service.dart:37-58,123,131`; `push_registration.dart:79-87` |
| Server mitigates stale tokens only at next register: `register()` deletes the same `fcm_token` for other users. | `backend/src/domain/devices.ts:11-20` |

### 1.6 E2EE & keys

| Finding | Where |
|---|---|
| Identity key, signing key, signed prekey, OTPs → `LocalKeyMaterial`, exported as one JSON blob → `e2ee_keys`. Ratchet sessions per peer (up to 3 each) → `e2ee_sessions`, **keyed by `peerId` only**. Both global per device. | `e2ee_manager.dart:105-114,444-483`; `e2ee_service.dart:152 (E2eeSession), :418, :423` |
| Server: one identity row per **user** (`user_identity_keys`, PK `user_id`), replaced on rotation; rotation deletes OTPs. `GET /api/v1/keys/me` returns the published identity (non-consuming). No notion of key epoch / rotation time (only `updated_at`, bumped by *every* republish). | `backend/src/domain/keys.ts:54-114`; `backend/src/http/key-routes.ts` (`/keys/me`); migration `000005_phase4.up.sql:14-21` |
| Doc claims reinstall/cleared data is recovered by the peer re-initiating; true only for the *peer-as-initiator* side. Messages encrypted to the old keys are lost forever. | `docs/e2ee.md:97-98,103-123,160+` |

### 1.7 Android backup & OS persistence

| Finding | Where |
|---|---|
| `android:allowBackup="false"` and `android:dataExtractionRules="@xml/data_extraction_rules"` already present. | `mobile/android/app/src/main/AndroidManifest.xml:14-15` |
| Rules exclude domains `sharedpref`, `database`, `file`, `external` in both `<cloud-backup>` and `<device-transfer>`. | `mobile/android/app/src/main/res/xml/data_extraction_rules.xml:12-23` |
| **Gap 1 – `root` domain not excluded.** `drift_flutter` / `path_provider` place the DB in `getApplicationDocumentsDirectory()` = `<data>/app_flutter`, which belongs to the **`root`** domain, *not* `file` (`getFilesDir`) or `database` (`getDatabasePath`). The DB is therefore not explicitly covered by the XML (it is only protected today by `allowBackup=false`; precedence of `allowBackup` vs `dataExtractionRules` differs across Android versions → do not rely on it). | `app_database.dart:86` + rules file |
| **Gap 2 –** no `android:fullBackupContent` for Android ≤ 11; `device_root`/`device_file`/`device_database` domains not excluded. | manifest / rules |
| **Gap 3 –** the rules-file comment says "Chat history … is re-synced from the server" (`data_extraction_rules.xml:9`) – wrong for E2EE history (see §1.3). | rules file |
| **Gap 4 –** if a backup *were* ever restored, secure-storage prefs would come back **without** their Keystore master key → `flutter_secure_storage` read errors; `TokenStore` has no handling (`token_store.dart:11,21-26`). | `token_store.dart` |
| `MainActivity.kt` is a bare Flutter activity (no storage channel). | `mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt` |

### 1.8 Backend sync surface

| Finding | Where |
|---|---|
| `GET /conversations` (list, last-message preview, unread count computed from `last_read_seq`) | `conversation-routes.ts:59`; `conversations.ts:358-440` (unread `:399`) |
| `GET /conversations/:id/messages` (page) and `/sync?after_seq=` — membership check, then full history slice; no per-member lower bound. Postgres and Scylla paths. | `message-routes.ts:40,51`; `messages.ts:201,233`; `scylla-messages.ts:159,186` |
| Message search | `messages.ts:275` |
| `conversation_members(conversation_id, user_id, role, last_read_seq, joined_at)` — **no `cleared_seq`**; messages are shared rows (cannot be physically deleted for one member). | `migrations/000001_init.up.sql:19-26` |
| Auth: `logout` revokes the presented refresh token only; `device_tokens` unregister at `user-routes.ts:156`; register `:139`. | `auth-routes.ts:156`; `user-routes.ts:139,156` |
| **Nothing on the server can currently express "this user cleared history up to X".** | — |

---

## 2. Target Architecture & Design Decisions

### 2.1 Per-user local partitioning

**AccountId** = first 16 hex chars of `sha256("cpchat.account.v1:" + userId)` (no raw ids/PII on disk).

| Resource | Location / key | Lifetime |
|---|---|---|
| SQLite | `<noBackupDir>/accounts/<id>/cpchat_<id>.sqlite` (+ `-wal`, `-shm`) | survives logout; deleted by Clear Data |
| E2EE keys / ratchet sessions | secure storage `acct.<id>.e2ee_keys`, `acct.<id>.e2ee_sessions` | survive logout; deleted by Clear Data |
| Partition integrity marker | secure storage `acct.<id>.partition_id` (random UUID) **and** the same value in DB table `account_meta` | detect "DB gone but keys present" and vice-versa (§2.6) |
| Media cache (`CacheManager` per account) | `<cacheDir>/accounts/<id>/media/` (OS-evictable; regenerable from network) | kept across logout; emptied by Clear Data / OS "Clear cache" |
| Upload temp files | `<cacheDir>/accounts/<id>/tmp/` | emptied on logout |
| Drafts (optional) | table `drafts` in the account DB | per account |
| Account registry | secure storage `accounts_index` (`[{accountId, userId, lastActiveAt}]`), `active_account_id` | device-global |
| Session credentials | `access_token`, `refresh_token`, `user_id`, `user_profile` | current session only (cleared on logout; semantics unchanged) |
| `device_id` | device-global (gateway routing key), unchanged | until OS Clear Data |

`<noBackupDir>` = Android `Context.getNoBackupFilesDir()`, obtained through a tiny `MethodChannel('cpchat/storage')` in `MainActivity.kt`. Files there are **excluded from Auto Backup and device transfer by the OS itself**, independent of any XML (defence in depth for §2.4). Fallback if the channel is unavailable: `getApplicationSupportDirectory()` + XML exclusion.

DB hardening: `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON`. Schema **v6**: `account_meta(key PK, value)` (owner `user_id` asserted on open – mismatch ⇒ close, delete, recreate, warn-log), `drafts`, and `local_conversations.cleared_seq INT DEFAULT 0` (§2.5).

New code: `lib/core/account/{account_id,account_paths,account_registry,account_store,account_scope,account_wiper,partition_guard}.dart`.

### 2.2 Account-scoped Riverpod graph

`authControllerProvider → currentUserIdProvider (select user.id; token rotation does not rebuild) → accountScopeProvider`.
Every user-bound provider **watches** `accountScopeProvider`, so an account change disposes the whole graph: `appDatabaseProvider`, `chatDaoProvider`, `apiClientProvider`, `e2eeManagerProvider`, `chatSocketProvider`, `messageNotifierProvider`, `mediaServiceProvider`, `mediaCacheProvider`, `pushRegistrationProvider`, `activeConversationIdProvider`, `conversationsProvider`, `messagesProvider`, `accessTokenProvider`, and all feature providers listed in §1.2. Device-global: `deviceIdProvider`, `appLoggerProvider` (buffer cleared on account change), `appLifecycleProvider`, `bootstrapProvider`.
`AccountScope { accountId, userId, epoch, isOpen, beginClose(), onClosed }`; every async continuation in `ChatSocket`, `E2eeManager`, DAO writers captures the epoch and **drops work if `!scope.isOpen`**.
A guard test enforces the rule (§5.1).

### 2.3 Logout & account-switch teardown (strict order)

Local teardown is deterministic and never depends on the network. Network calls are bounded (≤3 s each) and best-effort.

```
 0. UI: block sends, show "Signing out…"; scope.beginClose()  (epoch++ → stale async work fails closed)
 1. push.unregister()            // FCM token unregister (needs auth, so it goes first); best-effort
 2. notifications.cancelForAccount(accountId) + messageNotifier.reset()   // tray cleared
 3. socket.disconnect()          // stop reconnect timers, cancel in-flight sync, await barrier, normal close
 4. e2ee.flush()                 // await pending _persistSessions (ratchet advance must not be lost)
 5. api.logout()                 // revoke refresh token — needs the refresh token still present; best-effort
 6. await db.close()             // via DbGate (serialised per file); then clear image caches + account tmp
 7. tokenStore.clear()           // session pointers only: tokens, user_id, user_profile, active_account_id=null
                                 // does NOT delete the account DB or acct.<id>.e2ee_* (R2)
 8. authState = unauthenticated  // providers watching accountScopeProvider are invalidated/disposed; router → /auth;
                                 // navigator subtree keyed by accountId so no widget state survives
```
`chatDao.clearAll()` and `clearE2ee()` are **removed from logout**. If steps 1–6 time out, B still cannot reach A's data: different DB file, different key names, different cache dir. Forced sign-out (401/403 in `validateSession`, `providers.dart:~455-480`) uses the same sequence.

### 2.4 Same-user re-login (R2)

```
login(X) → registry.register(X) idempotent → active_account_id=X → authState=authenticated(X)
 → scope(X): open account DB (await any prior close of the same file), PartitionGuard.verify()
 → e2ee.bootstrap(): load acct.X.e2ee_keys → import, restore sessions, replenish OTPs (NO key regeneration)
     → GET /keys/me: compare server identity_key with local identity public key
         match    → continue
         mismatch → "key divergence" (e.g. X signed in on another device or server was reset) → §3.4 handling
 → socket.connect() → syncAll(): per-conversation cursor = max(lastSeq, cleared_seq) → incremental sync
 → missed E2EE messages decrypt in order using restored ratchets → flush X's outbox (idempotent by client_msg_id)
 → request notification permission, register push
```
Legacy-upgrade case in §3.1.

### 2.5 Clear Data — three levels

Terminology: the user-facing term **"Clear Data"** is split into explicit levels. Android Settings → Clear Storage is Level 3 and cannot be intercepted; Levels 1–2 are in-app.

| Level | Trigger | Local | E2EE keys | Server | Result on re-login |
|---|---|---|---|---|---|
| **L1 – Clear chat history** (stay signed in) | Settings → Privacy → "Clear all chats" (or per-conversation "Clear chat") | wipe account DB rows (messages, outbox, previews, unread, drafts), empty media cache; **keep** keys & sessions & login; set local `cleared_seq`=server value | **kept** (future messages still decrypt) | `POST /conversations/:id/clear` or `POST /users/me/history/clear` ⇒ `conversation_members.cleared_seq = last_seq`, `last_read_seq ≥ cleared_seq` | History does **not** reappear (server serves only `seq > cleared_seq`), other devices informed via `history_cleared` WS frame. |
| **L2 – Reset this device & sign out** | Logout dialog checkbox / Settings → "Remove my data from this device" | delete whole partition (DB+WAL, media, drafts), delete `acct.<id>.*`, remove registry entry, then standard logout | **deleted**; next login generates fresh identity | L1 `history/clear` (best-effort, queued if offline) + normal logout; fresh keys at next login ⇒ server key epoch rotates (§2.6) | Behaves exactly like Level 3 (below) but initiated knowingly. |
| **L3 – OS Clear Data / reinstall** | Android Settings → Storage → Clear storage; uninstall | everything gone (OS) | gone (Keystore entries removed by OS) | **nothing** (client could not tell the server) | Server reconciles at next key publish (§2.6) — the design target of this section. |

**Why a server-side watermark is required (answer to the product question).**
- *Client-only wipe is insufficient.* After L1 the sync cursor resets to 0 (cursor lives in the wiped DB); `GET /sync?after_seq=0` re-serves the full history (`messages.ts:233`) → plaintext group history fully reappears; E2EE direct history reappears as stubs. Keeping the cursor locally while wiping rows would avoid that on *this* device but not after L2/L3.
- *Key reset alone is insufficient.* A new identity makes old direct ciphertext undecryptable but the server still returns it ⇒ stubs.
- ⇒ **A per-member sync watermark `cleared_seq` is required** for L1/L2, and **an automatic key-epoch watermark** is required for L3. Both reuse the same column.

### 2.6 Backend changes (migration `000009_history_watermark`)

```sql
ALTER TABLE conversation_members
  ADD COLUMN cleared_seq BIGINT NOT NULL DEFAULT 0 CHECK (cleared_seq >= 0);
ALTER TABLE user_identity_keys
  ADD COLUMN key_epoch  INT         NOT NULL DEFAULT 1,
  ADD COLUMN rotated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
-- down: drop the three columns
```

1. **Reads honour the watermark** (`messages.ts:201,233,275`, `scylla-messages.ts:159,186`, `conversations.ts:358-440`, routes `message-routes.ts:40,51`):
   - `requireMemberConversation` returns the member's `cleared_seq`.
   - `sync`: effective `after_seq = max(after_seq, cleared_seq)`; `page`: `seq > cleared_seq`; `search`: join members, `m.seq > cleared_seq`. `latest_seq` stays the true `last_seq`; response adds `cleared_seq`. Scylla slices by clustering `seq`, so a lower bound is a pure range change.
   - `list`: last-message preview and unread count use only `seq > cleared_seq` and `GREATEST(last_read_seq, cleared_seq)` (`conversations.ts:399,410-414`); each item carries `cleared_seq`. The conversation row itself stays in the list (empty preview).
2. **New endpoints** (auth required, idempotent, monotonic – `cleared_seq` never decreases):
   - `POST /api/v1/conversations/:id/clear` → sets `cleared_seq = conversations.last_seq`, returns `{cleared_seq}`.
   - `POST /api/v1/users/me/history/clear` → same for every membership (direct **and** group), returns `{conversations: n, cleared_at}`.
   - Optional: gateway frame `history_cleared {conversation_id, cleared_seq}` to the user's other live sockets.
3. **Key-epoch rotation clears readable-by-nobody history automatically** (`keys.ts:85-114`, POST `/keys`): in the same transaction as an identity *change* (previous row exists **and** `identity_public_key` differs — exactly the existing OTP-delete branch at `:106-109`): `key_epoch += 1`, `rotated_at = NOW()`, and for the user's **direct** conversations `cleared_seq = last_seq`, `last_read_seq = GREATEST(last_read_seq, last_seq)`. Groups are plaintext and untouched. A first-ever publish (no previous row) clears nothing. `GET /keys/me` additionally returns `key_epoch`, `rotated_at`.
   - Rationale: after a rotation the user's old direct ciphertext is cryptographically unreadable *by definition*; serving it only yields stubs. This makes OS Clear Data / reinstall / key reset behave identically with **no client heuristic**.
   - Capability gate: apply auto-clearing only if the publishing client sends `"history_watermark": true` in the `POST /keys` body (older clients' sync logic assumes a gapless cursor, see risk R-3).
4. **Stale device data after L3** (`devices.ts:11-20,37-40`, `refresh-tokens.ts`): old `device_tokens` row is already pruned by FCM `UNREGISTERED` handling (`fcm.ts:27-28,139`) and reassigned on register; optionally, on `POST /auth/login` with a *new* `device_id`, revoke refresh tokens bound to other `device_id`s only if product wants single-device sessions (not required — see Q6).
5. **Push payload**: add `recipient_user_id` to FCM data so the headless handler can drop pushes for non-active accounts (`fcm.ts`; notification path in `gateway`/domain).
6. **API docs/tests**: `docs/api-spec.yaml`, `docs/ws-protocol.md` (`history_cleared`), `docs/e2ee.md` (replace the "cleared app data" sentence at `:97-98` with the epoch/watermark model), `docs/architecture.md`.

### 2.7 L3 re-login design (OS Clear Data → same user A logs in)

Client detects a **fresh partition** (no `acct.A.partition_id`, no DB, no keys) → this is the same path as a first login on a new device.

```
login(A) → fresh partition created
 → e2ee.bootstrap(): no keys → generate → publish with history_watermark=true
     → server: identity differs from stored → key_epoch++, rotated_at=now, OTPs deleted,
       direct conversations cleared_seq = last_seq        (stubs impossible)
 → syncAll(): list returns cleared_seq per conversation; cursor = cleared_seq; sync returns only newer messages
 → groups (plaintext): server history still exists → product decision D1 (below)
 → A sends first message in a direct chat → new X3DH session → peer adopts it (docs/e2ee.md:103-123)
```
Known inherent loss: direct messages peers sent *between* A's wipe and A's re-login (encrypted to the old bundle) and any peer message sent on the old ratchet *after* re-login but *before* A (or the peer) re-initiates are undecryptable. Mitigations: (i) after re-login, A proactively opens a session by fetching peer bundles lazily on first send (existing); (ii) post-watermark undecryptable *live* messages render **one** collapsed system row ("Secure session reset – ask them to resend") instead of N stubs; (iii) copy in the UI: "Encrypted history is not restored on a new or cleared device."
Client defence in depth (works against servers/clients without the watermark): during **historic backfill** (REST sync, not live frames), an incoming E2EE body that fails to decrypt and has `created_at < /keys/me.rotated_at` is **not stored** (counted, one summary row at most). Implemented in `ChatSocket._persistServerMessage`/`_decryptForStorage` (`ws_client.dart:657-716`).

**D1 (needs your decision): plaintext group history after OS Clear Data.** Options: (a) *Restore* group history (readable plaintext, normal behaviour of a new device); (b) *Start fresh*: after a fresh-partition login the app shows a one-time prompt and, if the user picks "Start fresh", calls `POST /users/me/history/clear`; (c) always start fresh silently. Recommendation: **(b) with "Start fresh" preselected**, because R3 says "all chat history must be gone", but silent loss of group history on a new phone (not a Clear Data) would be a surprise.

### 2.8 Android backup & storage hygiene (all levels)

1. `AndroidManifest.xml`: keep `allowBackup="false"` and `dataExtractionRules`; add `android:fullBackupContent="@xml/backup_rules"` (Android ≤ 11) with `<full-backup-content><exclude domain="root|file|database|sharedpref|external|device_root|device_file|device_database" path="."/></full-backup-content>` (one `exclude` per domain).
2. `data_extraction_rules.xml`: add `root`, `device_root`, `device_file`, `device_database` excludes to **both** `<cloud-backup>` and `<device-transfer>`; correct the stale comment (`:9`) — chat history is *not* silently re-synced; E2EE history is intentionally non-restorable.
3. Place DB and account partitions in `getNoBackupFilesDir()` via `MainActivity.kt` method channel (OS-level exclusion irrespective of XML).
4. `TokenStore`: wrap every read in a guard; a `PlatformException`/decrypt failure (Keystore key lost, restored prefs) ⇒ treat as **signed out + fresh partition** (never crash, never use partial state); set `AndroidOptions(resetOnError: true)` consistent with that policy.
5. Verification (no APK build): static test that parses both XML files and asserts every domain is excluded; `adb shell bmgr`/`dumpsys backup` + restore checks in manual QA (§5.2).

### 2.9 Partition integrity guard (inconsistency recovery)

On every account open (`PartitionGuard.verify`):
| State | Action |
|---|---|
| DB ✓ keys ✓ markers equal | normal |
| DB ✗ keys ✓ (history gone, ratchets advanced) | ratchet state is now useless against re-served ciphertext ⇒ treat as fresh: delete `acct.<id>.*`, regenerate keys on bootstrap (server rotation clears direct history) |
| DB ✓ keys ✗ (Keystore loss) | keep DB (readable plaintext history remains valuable), regenerate keys; rotation clears undecryptable direct history on the server; old rows stay |
| markers differ / `account_meta.owner_user_id` ≠ scope user | delete partition, fresh |

---

## 3. Edge Cases & Failure Modes

### 3.1 Migration of the existing single-file DB / global keys (upgrade from current build)
- Marker `local_layout` (secure storage). Absent ⇒ legacy layout.
- Legacy artifacts: DB `<documents>/cp_chat.sqlite` (+`-wal`), `e2ee_keys`, `e2ee_sessions`.
- **Session present at upgrade** (tokens + `user_id`): adopt for that user: copy → verify (open + `PartitionGuard`) → write markers → delete legacy. Ownership double-check with `GET /keys/me` (identity key equality) when online; if mismatch ⇒ discard keys only (DB kept).
- **No session**: legacy DB is empty by construction (old logout wiped it, `providers.dart:515`); delete it. Legacy keys are **ownerless**: *quarantine* them (`legacy.e2ee_*`); at the first login by user X, adopt **only if** `/keys/me` identity equals the legacy local identity key (exact proof, no new endpoint), else delete. Quarantine expires on first mismatch or after 30 days.
- Idempotent and crash-safe (copy → verify → mark → delete; janitor completes interrupted runs). Tests with fake secure storage + temp dirs for all branches.
- Existing users already have stub-filled/empty histories; no retroactive fix other than L1 "Clear chat" (also hides server history).

### 3.2 Drift/SQLite open-close races (rapid logout → login)
- `DbGate`: one serialised open/close queue **per file**; `open(X)` awaits any pending `close(X)` future. A→B involves different files (no contention); A→A awaits close.
- `AppDatabase.close()` awaited in logout step 6 *before* tokens are cleared and before state flips; late writers see a closed DB ⇒ DAO wrapper catches `DriftWrappedException`/"closed" and drops (epoch check first).
- WAL + `busy_timeout=5000`; wipe closes the DB, then deletes `.sqlite`, `-wal`, `-shm`, `-journal`.
- Wipe is resumable: write `wipe_pending.<id>` marker first; janitor finishes after a crash.
- Single-isolate assumption holds (FCM headless isolate does **not** open the DB; keep it that way — it only posts tray notifications).

### 3.3 Notification tap for A while B is signed in (or nobody is)
- Local payload `{"a":"<accountId>","c":"<conversationId>"}`; notification id hashed from `(a,c)`; group/tag = `a`.
- Tap routing (`local_notification_service.dart:132-134`, cold start `:73-75`, FCM `fcm_service.dart:123,131`) ignores payloads where `a` ≠ active account (and clears them); with no session ⇒ no routing, no stored intent.
- Headless handler (`fcm_service.dart:37`): read `active_account_id` from secure storage; drop unless `recipient_user_id` hashes to it **and** a session exists.
- Logout cancels only that account's notifications (plus `cancelAll()` fallback); login of a different account cancels everything not tagged for it.

### 3.4 Same user, fresh key material (A after OS Clear Data) / key divergence
- Fresh keys ⇒ `device_id` also new (generated at `bootstrapProvider`, `providers.dart:360-367`); old `device_tokens` row pruned/reassigned; old `refresh_tokens` expire naturally (optional revoke, Q6).
- Server sees a new identity ⇒ rotation + direct watermark (§2.6). Peers: their cached session for A is now dead; A's first outbound message re-initiates (`ek/spk/opk` attached every message until answered, `docs/e2ee.md:92-98`) and peers adopt it. Until then peers' messages are undecryptable → collapsed "secure session reset" row; surface a prompt to the *peer* is out of scope (Q8).
- **Divergence without wipe** (A also logged in on another phone and published different keys; this phone's local keys ≠ `/keys/me`): do **not** overwrite local keys automatically. Behavior: keep readable local history, mark session `e2eeKeyMismatch`, block *sending* encrypted messages until the user chooses "Reset encryption on this device" (L2-like key reset: publish local→server? or regenerate) — default: regenerate + publish (rotation → direct watermark) — **Q4**.

### 3.5 Other
| Case | Handling |
|---|---|
| Logout while offline | Local teardown completes; `api.logout`/FCM unregister fail silently. Refresh token remains valid server-side until expiry (existing). Push for A may arrive in tray with no session ⇒ headless handler drops it (§3.3). |
| Clear (L1/L2) while offline | Local wipe immediate; server call queued in `pending_server_clear` (secure storage, per account) and retried at next authenticated start **before** `syncAll`; until done, the client keeps an in-DB `local_cleared_seq_floor` so re-sync never re-inserts older rows. L2 offline: partition deleted at once; `pending` flag survives in registry; the next login of that user runs it first. |
| L1 while messages in flight | Clear captures server `last_seq` from the clear response; messages arriving after it remain (seq > cleared). Outbox cleared; sends racing the clear are rejected by UI lock. |
| Another device of the same user | `history_cleared` frame (or next sync response's `cleared_seq`) makes it wipe affected conversations locally; if it was offline, it applies on next sync. |
| Backup restore in a lab (rules bypassed) | Secure-storage guard + `PartitionGuard` ⇒ fresh partition, no half-state. |
| Many accounts → disk | "Accounts on this device" screen with per-account L2; no auto-eviction (Q5). |
| Old clients vs watermark | Server changes are additive (`cleared_seq=0` default); auto-rotation clearing gated by capability flag; old clients ignore `cleared_seq` fields (see R-3). |

---

## 4. Phased Implementation Plan

Every phase is independently mergeable, ends green on `flutter analyze` + `flutter test` (+ backend typecheck/tests where touched), and **never builds an APK**. Recommended order: **P1 → P2 → P3 → P4a (backend) → P4b (client) → P5**; P4a can ship earlier because it is additive.

### Phase 1 — Android backup & storage hygiene
**Modify:** `mobile/android/app/src/main/AndroidManifest.xml` (`fullBackupContent`), `res/xml/data_extraction_rules.xml` (add domains, fix comment); **create:** `res/xml/backup_rules.xml`; `MainActivity.kt` (`cpchat/storage` channel → `noBackupFilesDir`); `lib/core/storage/token_store.dart` (error-guarded reads, `resetOnError`); `lib/core/storage/app_dirs.dart` (new).
**Acceptance:**
- Static XML test asserts every backup domain is excluded in cloud-backup, device-transfer and fullBackupContent.
- `AppDirs.noBackup()` returns a path under `no_backup` on Android and a temp path in tests.
- Simulated `PlatformException` on read ⇒ `hydrateAuthState` returns unauthenticated, no crash (widget/unit test).
- `flutter analyze`, `flutter test` green.

### Phase 2 — Per-user DB / E2EE / media partitioning + migration
**Create:** `lib/core/account/*` (§2.1); `lib/core/media/account_media_cache.dart`; **modify:** `app_database.dart` (path from `AccountPaths`, schema v6 `account_meta`, `drafts`, `cleared_seq`, WAL/busy_timeout), `chat_dao.dart` (scope-aware, closed-DB guard, `clearAll` kept for L1), `token_store.dart` (session-only keys + deprecated legacy readers), `e2ee_manager.dart` (use `AccountStore`; `selfId` from scope at `:171`; `flush()`; closed-scope guards), `media_service.dart:100` (tmp under account), `features/chat/media_message.dart:52,89` + avatar widgets (`cacheManager`, account-prefixed `cacheKey`), `providers.dart` (`currentUserIdProvider`, `accountScopeProvider`; scope DB/DAO/e2ee/media providers), `lib/core/account/legacy_migration.dart`.
**Acceptance:**
- A writes rows/keys → B logs in → B's DB empty, B bootstraps **different** identity, A's `acct.<id>.*` untouched.
- Legacy migration matrix (§3.1) passes: session-present, no-session quarantine, ownership mismatch, crash mid-copy.
- Owner assertion mismatch recreates the DB.
- Media cache manager instances differ per account; in-memory `ImageCache` cleared on switch.
- Existing tests updated: `chat_dao_test`, `e2ee_manager_test`, `e2ee_delivery_test`, `media_and_receipts_test`, `cold_start_test`.

### Phase 3 — Logout / account-switch teardown & notification isolation
**Modify:** `providers.dart` (`AuthController.logout` per §2.3 — remove `clearAll` at `:515`; `SessionLifecycle` awaits prior `stop`; scope all remaining providers incl. `apiClientProvider`, `chatSocketProvider`, `presence/people/groups/metadata`), `ws_client.dart` (epoch checks in `_handleMessage :597`, `_persistServerMessage :657`, `_syncConversation :338`, `flushOutbox :493`; cancel token in `disconnect :197`), `local_notification_service.dart` (payload `{a,c}`, per-account cancel, tag), `fcm_service.dart` (account-checked headless/tap handlers), `push_registration.dart` (bounded unregister), `features/profile/my_profile_screen.dart:181,306` (logout dialog with L2 option wired in P5), `lib/main.dart`/router (keyed navigator subtree), `app_logger.dart` (clear on switch).
**Acceptance:**
- Tests (`session_runtime_test`, `notifications_test`, new `account_isolation_test`): A→B→A flows; stalled socket / failing `api.logout` / failing unregister still end signed-out with data intact; late sync after `beginClose` leaves B's DB unchanged; foreign-account notification payload dropped (tap, cold start, headless); rapid A→A re-login awaits DB close.
- Static guard test: every registered user-bound provider is disposed when `accountScopeProvider` changes; no `FlutterSecureStorage(`, `DefaultCacheManager`, `getTemporaryDirectory`, `driftDatabase(` outside their owning modules.

### Phase 4a — Backend history watermark & key epoch (additive)
**Create:** `backend/migrations/000009_history_watermark.up.sql` / `.down.sql`. **Modify:** `domain/conversations.ts` (member `cleared_seq`; `list` `:358-440`; `clear`/`clearAll`), `domain/messages.ts` (`page :201`, `sync :233`, `search :275`), `domain/scylla-messages.ts` (`page :159`, `sync :186` lower bound), `http/message-routes.ts` (`:40,51`), `http/conversation-routes.ts` (`POST /:id/clear`, list shape), `http/user-routes.ts` (`POST /users/me/history/clear`), `domain/keys.ts:85-114` (epoch, rotation watermark, `history_watermark` capability), `http/key-routes.ts` (`POST /keys` flag; `/keys/me` returns `key_epoch`, `rotated_at`), `lib/fcm.ts` + notification path (`recipient_user_id`), gateway frame `history_cleared` (`gateway/chat-gateway.ts`), `docs/api-spec.yaml`, `docs/ws-protocol.md`, `docs/e2ee.md`.
**Acceptance (new/updated backend tests: `messages.test.ts`, `scylla.test.ts`, `keys.test.ts`, `notifications.test.ts`, new `history-watermark.test.ts`):**
- After clear, `sync(after_seq=0)`, `page`, `search` return only `seq > cleared_seq`; `latest_seq` unchanged; unread = 0; later messages appear; `cleared_seq` monotonic; non-members get 403/404.
- Identity change (with capability flag) ⇒ `key_epoch+1`, direct `cleared_seq=last_seq`, groups untouched; same-identity republish ⇒ no change; first publish ⇒ no change; without the flag ⇒ no auto-clear.
- Works on both Postgres and Scylla message paths. `npm run typecheck && npm test` green. Backend deploys **before** the client.

### Phase 4b — Client clear-data & post-wipe sync handling
**Modify/create:** `lib/core/network/api_client.dart` (`clearConversation`, `clearAllHistory`, `keysMe` incl. epoch; models in `models/models.dart` get `clearedSeq`), `chat_dao.dart` (`clearConversationRows`, `applyClearedSeq`, cursor = `max(lastSeq, clearedSeq)`), `ws_client.dart` (seed cursors from list `cleared_seq`; accept first message `seq = cleared_seq+1`; handle `history_cleared`; historic-backfill undecryptable-drop + one summary row; `pending_server_clear` retry before `syncAll`), `e2ee_manager.dart` (send `history_watermark: true`; reconcile with `/keys/me` per §2.4/§3.4; collapsed "session reset" state), `account_wiper.dart` (L1/L2, resumable), `partition_guard.dart` (§2.9), `features/chat/chat_screen.dart:709-711` (collapsed system row instead of per-message stubs), `features/auth/…` (post-login D1 prompt on fresh partition).
**Acceptance:**
- L1: rows gone, keys kept, server `cleared_seq` set; re-login/resync adds **zero** historic rows; new messages decrypt.
- L2: partition + keys + registry entry gone; next login = fresh path; no stubs for direct chats; groups per D1.
- L3 simulation (fresh storage + existing server fixture of N old ciphertexts): after login 0 stub rows, only post-login messages visible.
- DB-missing/keys-present and keys-missing/DB-present recoveries behave per §2.9.
- Offline clear retried; second device applies `history_cleared`.

### Phase 5 — UX, docs, automated & manual verification
**Create/modify:** logout dialog (checkbox "Also remove my data from this device" + E2EE warning), Settings → Privacy ("Clear all chats", per-chat "Clear chat"), optional "Accounts on this device"; `docs/e2ee.md`, `docs/architecture.md`, `README` troubleshooting; release notes explaining that encrypted history is intentionally not restorable on new/cleared devices.
**Acceptance:** widget tests for dialogs/flows; full QA matrix (§5.2) signed off; docs updated; `flutter analyze`, `flutter test`, backend typecheck/tests green; no APK built by agents.

---

## 5. Verification & Test Matrix

### 5.1 Automated

| Area | Test (new = N, updated = U) |
|---|---|
| Account foundation | N `account_id_test` (hash stable, no raw id), N `account_registry_test`, N `legacy_migration_test` (all §3.1 branches), N `partition_guard_test` (§2.9 table) |
| R1/R2 end-to-end (provider level, temp dirs + fake secure storage) | N `account_isolation_test`: A seed → logout → B empty/ different keys/ no notifications → B logout → A re-login: history readable offline, 2 missed E2EE messages decrypt in order, outbox flushed once |
| Stale async | N: sync/decrypt started under A, `beginClose`, B logs in, release ⇒ B DB unchanged |
| Logout robustness | U `session_runtime_test`: stalled socket / failing API / failing unregister |
| E2EE | U `e2ee_manager_test`, `e2ee_delivery_test`: per-account keys; B never loads A's; sessions separated; `/keys/me` mismatch flag; flush before close |
| DAO | U `chat_dao_test` (clearAll only L1; cursor `max(lastSeq,clearedSeq)`), N cleared-seq seeding / first message `cleared_seq+1` accepted |
| Sync | U `sync_recovery_test`; N historic-backfill drops undecryptable pre-rotation bodies, one summary row |
| Notifications | U `notifications_test`: payload `{a,c}`, foreign-account tap/cold-start/headless dropped |
| Media | U `media_and_receipts_test`: cache manager per account, emptied on wipe |
| Wipe | N `account_wiper_test`: L1 keeps keys, L2 removes DB/-wal/-shm/media/keys/registry, resumable after simulated crash, offline `pending_server_clear` |
| Android hygiene | N `android_backup_rules_test` (parse XML, all domains excluded) |
| Guards | N provider-scoping + banned-API static test (§Phase 3) |
| Backend | N `history-watermark.test.ts`; U `messages.test.ts`, `scylla.test.ts`, `keys.test.ts` (rotation, capability flag, `/keys/me` epoch), `notifications.test.ts` (`recipient_user_id`), `gateway.test.ts` (`history_cleared`) |

Gates: `cd mobile && flutter analyze && flutter test`; `cd backend && npm run typecheck && npm test`. No APK/AAB.

### 5.2 Manual QA (two test accounts A/B and a peer P; Android 11 and 14 devices; builds supplied by the owner)

| # | Steps | Expected |
|---|---|---|
| a | A logs in, chats with P (E2EE) + group, leaves unsent message offline, logs out → B logs in | B: empty list; no tray notifications; no A avatars (media cache) ; Settings → no A drafts; `adb shell run-as <pkg> ls no_backup/accounts` shows separate dirs; B's `/keys/me` ≠ A's. |
| b | B chats with P, logs out → A logs back in | A's full readable history incl. E2EE; messages P sent while A was out arrive and decrypt; unsent offline message sent once; unread counts correct; B's data not visible. |
| c | A has history; Android Settings → Apps → CP Chat → **Clear storage**; reopen, log in as A | Auth screen first (tokens gone). After login: **0 stubs** in direct chats; list shows conversations with empty preview; unread 0; D1 prompt for groups; A sends to P → P receives; P replies → A reads; P's pre-login-on-old-ratchet message appears as one "secure session reset" row at most. Backend: `key_epoch` incremented, direct `cleared_seq = last_seq`. |
| c2 | Same as (c) after backup-restore attempt: `adb shell bmgr backupnow <pkg>`, uninstall/reinstall, `bmgr restore` | No data restored (no DB, no tokens, no keys) ⇒ identical to (c). Repeat on Android 11 (fullBackupContent) and 14 (dataExtractionRules); also device-to-device transfer rules verified by inspection. |
| d | In-app **Clear all chats** as A (signed in), then force-close, reopen, reconnect; then logout/login A | Lists empty; history absent after resync; new messages arrive and decrypt (keys kept); second device (if available) wipes via `history_cleared`; airplane-mode variant retries clear on reconnect. |
| e | In-app **Log out & remove my data** as A, log back in | Same as (c). |
| f | Push for A pending; A logs out; B logs in; tap A's old notification / cold start tap | Ignored; B's UI unaffected; no crash. |
| g | Rapid A→logout→A and A→logout→B→logout→A loops (10×) | No "database locked/closed" errors in log; data intact. |
| h | Upgrade from current build with A signed in (and variant: signed out) | A's keys/DB adopted (or quarantined keys adopted only if `/keys/me` matches); no cross-user exposure. |
| i | Keystore failure simulation (disable lock-screen / clear credentials on test device) | App treats as signed-out + fresh partition, no crash. |

---

## 6. Risks

| # | Risk | Mitigation |
|---|---|---|
| R-1 | A user-bound provider/cache left unscoped | registry + guard test; PR checklist |
| R-2 | Ratchet state lost on abrupt close | `e2ee.flush()` before DB close; persist after each advance (existing) |
| R-3 | Old clients mis-handle `cleared_seq` (gap check at `ws_client.dart:617-621`, ordering check `:348`) | additive server fields; auto-rotation clearing gated by capability flag; ship client with P4b before enabling flag broadly |
| R-4 | Auto-clear on rotation also hides pre-E2EE plaintext direct history (Phase 1-3 messages) | documented; acceptable (Q7) |
| R-5 | Legacy migration edge cases | quarantine + `/keys/me` ownership proof; idempotent steps; tests |
| R-6 | Privacy trade-off of keeping A's DB after logout on a shared device | explicit L2; optional SQLCipher (per-account key in Keystore) follow-up (Q2) |
| R-7 | `noBackupFilesDir` channel failure | fallback + XML exclusion |
| R-8 | Peers stuck with dead sessions after A's reset | A's first send re-initiates; collapsed row UX; documented limitation (Q8) |

---

## 7. Explicit Open Decisions / Trade-offs (please confirm before implementation)

1. **Retention on logout (R2 vs privacy).** Keeping A's isolated DB and keys on a shared device after logout is required for R2 but means A's data remains on disk (protected by app sandbox + Keystore, not by A's password). Confirm default "retain", with L2 "remove my data from this device" offered at logout. *Recommendation: retain.*
2. **At-rest encryption (SQLCipher) now or later?** Would make a closed account's DB unreadable without Keystore access; adds APK size/perf cost. *Recommendation: follow-up.*
3. **Scope of "Clear Data".** OS Clear Data only, or also in-app buttons? *Recommendation: both* — OS Clear Data is automatically correct via the key-epoch watermark; in-app L1 (clear chats, keep login/keys) and L2 (reset device) are needed to guarantee server history does not re-sync when the user stays signed in, and OS Clear Data **cannot** be intercepted to tell the server.
4. **Key divergence policy** (§3.4): block-and-ask vs auto-regenerate when local keys ≠ `/keys/me` (e.g. user signed in on a second phone). *Recommendation: block sending + one-tap "Reset encryption on this device".*
5. **Inactive-account retention:** never auto-delete vs evict after N days (history lost for E2EE). *Recommendation: never auto-delete.*
6. **Revoke other refresh tokens / sessions on login from a new `device_id`?** (single-device sessions) — product choice; not required for correctness.
7. **Pre-E2EE plaintext direct history** is hidden on rotation: acceptable? (Otherwise restrict watermark to seq ≥ first encrypted message.)
8. **Peer-side UX** after a user's key reset (banner "Safety code changed" for the peer, `docs/e2ee.md` "Trust on first use" section) – in scope or later?
9. **D1 group-history policy after OS Clear Data**: restore / prompt (recommended) / always fresh.
10. **Backend release ordering:** OK to ship migration `000009` and endpoints before the client, with the capability-gated auto-clear enabled after client rollout?

---

## 8. Out of Scope

True multi-device E2EE per user (server stores one identity per user), simultaneous multi-account sessions, group E2EE, physically deleting server messages (shared rows; watermark is a per-member view), server-side account deletion.

## 9. Definition of Done

R1, R2, R3 pass in automated tests and the manual matrix (a–i); no user-bound state outside the account namespace (guard tests); logout never deletes data; L1/L2 are complete, idempotent and resumable; after any Clear Data path, re-login shows zero historic stubs and no restored history; Android backup/transfer domains all excluded and DB in `no_backup`; legacy installs upgrade without cross-user exposure; docs updated; `flutter analyze`, `flutter test`, backend typecheck/tests green; no APK built.
