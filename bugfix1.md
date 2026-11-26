# Bugfix Plan 1: Decrypt E2EE Push Notifications in Terminated/Closed State

**Status:** Planning only. No application source code, migrations, or tests have been modified by this document.  
**Repo Rule 0 (`AGENTS.MD`):** **Never build an APK or App Bundle (`flutter build apk` / `appbundle`, Gradle `assemble*` / `bundle*`).** All automated verification uses `cd mobile && flutter analyze && flutter test` and `cd backend && npm run typecheck && npm test`. Real-device manual QA (§5.2) runs via `flutter run -d android` or owner/CI-supplied builds.

---

## 1. Executive Summary & Root Cause

### 1.1 Symptom
- **App open (foreground) or minimized (backgrounded, process alive):** Incoming direct-chat E2EE notifications display the **actual decrypted plaintext** message.
- **App terminated / swiped away from recents:** Incoming direct-chat E2EE notifications arrive on the Android device, but the notification body displays **`"Encrypted message"`** instead of the actual message text.

### 1.2 Why Foreground / Minimized Works (WebSocket + Local Notification — NOT FCM)

When the app is open or minimized (not swiped away), notifications do **not** come from FCM at all:

1. **Live WebSocket stays open while minimized:** `didChangeAppLifecycleState()` in `mobile/lib/main.dart:227-229` only updates `appLifecycleProvider`; nothing disconnects `ChatSocket`, which maintains the TCP connection via a 25 s heartbeat (`mobile/lib/core/network/ws_client.dart:56, 989-995`).
2. **Backend skips FCM:** In `ChatGateway.deliverStoredInner()` (`backend/src/gateway/chat-gateway.ts:526-533`), the gateway fans out the `message` WebSocket frame via `this.route(memberId, messageEvent)` and then calls `this.maybeNotify(...)`. `maybeNotify()` calls `await this.hasConnectedDevice(userId)` (`chat-gateway.ts:608-611, 660-665`), finds the open socket, and **returns early without sending FCM**.
3. **Client decrypts & persists before notifying:**
   - `ChatSocket._handleMessage()` (`mobile/lib/core/network/ws_client.dart:686-726`) receives the `e2ee:v1:...` ciphertext frame, ensures contiguous `seq` ordering, and calls `_persistServerMessage()` (`ws_client.dart:754-798`).
   - `_persistServerMessage()` checks `_alreadyReadable(message)` (`ws_client.dart:502-511`), then calls `_decryptForStorage()` (`ws_client.dart:800-831`) → `E2eeManager.plaintextFor()` (`mobile/lib/core/crypto/e2ee_manager.dart:261-356`) → `E2eeService.decrypt()` (`mobile/lib/core/crypto/e2ee_service.dart:617-656`).
   - `_persistServerMessage()` stores the **decrypted plaintext** in Drift SQLite (`LocalMessages`) via `ChatDao.upsertServerMessage()` (`mobile/lib/core/database/chat_dao.dart:400-447`).
   - `_emitIncoming()` (`ws_client.dart:728-747`) reads the stored plaintext row from `ChatDao` and fires `onIncomingMessage` → `MessageNotifier.onLiveMessage()` (`mobile/lib/core/providers.dart:347-352`, `mobile/lib/core/notifications/message_notifier.dart:44-65`).
4. **Local tray rendering:** `MessageNotifier.onLiveMessage()` applies `NotificationPolicy.shouldNotify()` and `NotificationPolicy.format()` (`mobile/lib/core/notifications/notification_policy.dart:14-59`) and calls `LocalNotificationService.showMessageNotification()` (`mobile/lib/core/notifications/local_notification_service.dart:162-196`) on channel `cpchat_messages` with the decrypted text.

### 1.3 Why Terminated State Displays `"Encrypted message"` (File-by-File Root Cause)

When the app is terminated/swiped away, the OS kills the process and closes the WebSocket (`ChatGateway.onClose`, `chat-gateway.ts:255-270`). Delivery falls back 100% to **FCM**, where **two direct root causes** prevent client-side decryption:

| # | Layer | Exact Location | What Happens Today |
|---|---|---|---|
| **RC-1** | Backend FCM payload | `backend/src/gateway/chat-gateway.ts:591-596, 628-647` & `backend/src/lib/fcm.ts:87-112` | `ChatGateway.notificationPreview()` sees `isEncryptedContent(message.content)` and sets `preview = 'Encrypted message'`. `NotificationService.notify()` then sends an FCM multicast containing **both a `notification` block (`notification: { title, body: "Encrypted message" }`) and a `data` block**. On Android, any FCM message with a `notification` block while the app is backgrounded/terminated is **intercepted and rendered directly by Android's `FirebaseMessagingService`** with the literal string `"Encrypted message"`—the Flutter background isolate never renders the banner. |
| **RC-2** | Backend `data` omissions & Mobile headless handler | `backend/src/lib/fcm.ts:97-105` & `mobile/lib/core/notifications/fcm_service.dart:22-35, 58-110` | Even without a `notification` block: (a) the FCM `data` map omits the E2EE ciphertext `content`, `client_msg_id`, `seq`, `created_at`, and `conversation_type`; (b) `resolveHeadlessFcmDisplay()` (`fcm_service.dart:63`) explicitly exits if `message.notification != null`; (c) `notificationContentFromFcm()` (`fcm_service.dart:22-35`) hardcodes `body: message.notification?.body ?? 'New message'`; and (d) `firebaseMessagingBackgroundHandler()` (`fcm_service.dart:95-110`) never loads E2EE keys, never decrypts, and never opens SQLite (citing the earlier single-isolate assumption in `plan.md §3.2`). |

### 1.4 Secondary Hidden Blockers Discovered During Codebase Audit

Simply removing the FCM `notification` block and calling `E2eeManager` + `AppDatabase` from `firebaseMessagingBackgroundHandler` would trigger **four severe production bugs** unless solved explicitly in the design:

1. **`MainActivity.kt` storage `MethodChannel` does not exist in the headless background isolate (CRITICAL DATA-LOSS RISK):**
   - `MainActivity.configureFlutterEngine()` (`mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt:17-27`) registers `MethodChannel("cpchat/storage")` to return `Context.getNoBackupFilesDir()` (`<data>/no_backup`).
   - When the app is terminated, FCM launches a headless `FlutterEngine` via `FLTFireBGExecutor` **without launching `MainActivity`**. `FLTFireBGExecutor` only calls `GeneratedPluginRegistrant.registerWith(engine)`.
   - Consequently, `AppDirs.noBackupDir()` (`mobile/lib/core/storage/app_dirs.dart:75-97`) catches `MissingPluginException` and silently falls back to `getApplicationSupportDirectory()/no_backup` (`<data>/files/no_backup`)—a **completely different directory**!
   - The background isolate would write decrypted messages into a **separate SQLite file** while advancing the real `acct.<id>.e2ee_sessions` in secure storage. When the main app opens later, it would sync from its own DB, attempt to re-decrypt with an already-advanced ratchet, and **permanently fail with `"Unable to decrypt this message"`**.
2. **`TokenStore` defaults to `AndroidOptions(resetOnError: true)` (CRITICAL KEY-WIPE RISK):**
   - `TokenStore` (`mobile/lib/core/storage/token_store.dart:22-24`) configures `FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: true))`.
   - If an FCM push wakes the background isolate during Direct Boot (Before First Unlock) or a transient Android Keystore lock/error, `resetOnError: true` would **wipe all secure-storage entries—destroying the user's session tokens and E2EE private identity keys**.
3. **Symmetric ratchet has no skipped-message key storage & `E2eeManager` persists sessions before DB write:**
   - `E2eeService._decryptWith()` (`mobile/lib/core/crypto/e2ee_service.dart:757-791`) advances `session._receiving.index` forward irreversibly (`docs/e2ee.md:176-181`).
   - Decrypting an out-of-order push (`seq > localCursor + 1`) would advance the ratchet past missing earlier messages **and** jump `ChatDao.localMaxSeq()`, permanently skipping and breaking those earlier messages.
   - `E2eeManager._plaintextFor()` (`e2ee_manager.dart:341`) calls `_persistSessions()` *before* returning plaintext to the caller; a process kill between session persist and SQLite commit would permanently lose the message.
4. **Main-isolate / Background-isolate concurrency hazards:**
   - If an FCM push arrives while the main isolate is still alive (minimized with momentarily dropped WS, or mid-launch), two isolates sharing `cpchat_<id>.sqlite`, `acct.<id>.e2ee_sessions` (cached in memory by main isolate's `E2eeManager`), and single-use rotating refresh tokens (`ApiClient._performRefresh`, `api_client.dart:753-779` — reuse revokes the entire token family!) will corrupt ratchet state or trigger forced logout.
5. **Foreground FCM parity gap:**
   - `_onForegroundMessage()` (`mobile/lib/main.dart:274-293`) currently calls `notificationContentFromFcm()` → `MessageNotifier.onForegroundFcm()`. Once FCM becomes `data`-only (`message.notification == null`), foreground FCM pushes arriving during a brief WS reconnect would regress to `"New message"` unless routed through the same decrypt/persist pipeline.

---

## 2. Target Architecture & Data Flow

### 2.1 Core Architectural Principles

1. **Strict E2EE Preservation:** Plaintext **never** leaves the sender's device unencrypted and **never** appears in FCM payloads or server logs. For direct text messages, FCM carries only the `e2ee:v1:...` ciphertext envelope (if within the 4 KB FCM data budget) or a ciphertext-omitted indicator prompting an authenticated REST sync fetch.
2. **High-Priority `data`-Only FCM for Capable Clients:** Upgraded clients advertise `push_version: 2` on `POST /api/v1/devices/fcm-token`. The backend sends **high-priority `data`-only** FCM messages (`android: { priority: 'high' }`, **no** `notification` block) to `push_version >= 2` devices so Android invokes `firebaseMessagingBackgroundHandler` even when terminated. Older APKs (`push_version == 1`) keep receiving legacy `notification + data` payloads without regression.
3. **Single-Owner Concurrency Model:**
   - **Main isolate alive** (foreground or minimized): Main isolate registers a `ReceivePort` via `IsolateNameServer` (`'cpchat_main_fcm_port'`). `firebaseMessagingBackgroundHandler` detects it and **delegates** the push payload to the main isolate, which owns the live `AccountScope`, `AppDatabase`, `E2eeManager`, `ApiClient`, and `MessageNotifier`. Zero dual-isolate DB/ratchet/token contention.
   - **Main isolate terminated:** `IsolateNameServer` lookup returns `null`. The background isolate acquires an exclusive OS advisory file lock (`<partitionDir>/.partition.lock` via `RandomAccessFile.lock(FileLock.exclusive)`), runs strictly sequentially inside an in-isolate queue, decrypts, writes SQLite **first**, then commits `acct.<id>.e2ee_sessions`, closes SQLite, releases the lock, and displays the local notification. `SessionLifecycle._start()` in the main isolate acquires the same `.partition.lock` before `PartitionGuard.verify()` and `E2eeManager.bootstrap()`, guaranteeing a race-free handoff if the user opens the app mid-push.
4. **Canonical Storage Path Across All Engines:** Replace the `MainActivity`-only `cpchat/storage` channel with a local in-repo Android `FlutterPlugin` (`mobile/packages/cpchat_storage_dirs`) registered automatically by `GeneratedPluginRegistrant` in **both** the main `FlutterEngine` and `FLTFireBGExecutor`'s background `FlutterEngine`.
5. **Contiguous Sequence & Crash-Safe Write Order:**
   - Only decrypt inline when `seq == effectiveCursor + 1`.
   - When `seq > effectiveCursor + 1` (gap) or `content_omitted == "true"` (>4 KB ciphertext), run an authenticated `GET /api/v1/conversations/:id/sync?after_seq={cursor}` to decrypt and persist every missing message **strictly in ascending `seq` order**.
   - Always commit decrypted plaintext to SQLite **before** writing updated `acct.<id>.e2ee_sessions` to secure storage. (If killed in between: SQLite already holds readable plaintext so `_alreadyReadable()` skips re-decryption, and the symmetric ratchet can skip forward cleanly on the next message `i+1`.)

### 2.2 End-to-End Data Flow (Terminated App)

```mermaid
sequenceDiagram
    autonumber
    participant Sender as Sender App
    participant GW as ChatGateway & FCM (Backend)
    participant FCM as Android FCM / FLTFireBGExecutor
    participant BG as Background Dart Isolate
    participant Lock as .partition.lock + SQLite + Keystore
    participant API as Backend REST API
    participant Tray as LocalNotificationService (Android Tray)
    participant Main as Main Isolate (On Tap / Resume)

    Sender->>GW: WS send (e2ee:v1:... ciphertext)
    GW->>GW: Persist msg (seq=N), hasConnectedDevice(recipient)==false, status!=dnd
    GW->>FCM: sendEachForMulticast(fids[v2], data-only, android.priority=high)
    Note over GW,FCM: data includes conversation_id, conversation_type, message_id,<br/>client_msg_id, seq, sender_id, sender_name, conversation_name,<br/>recipient_user_id, msg_type, created_at, content (if <= budget) or content_omitted=true
    FCM->>BG: Wake headless FlutterEngine -> firebaseMessagingBackgroundHandler(msg)
    BG->>BG: Check IsolateNameServer('cpchat_main_fcm_port') -> null (app terminated)
    BG->>Lock: Read TokenStore.forBackground(resetOnError:false)
    BG->>BG: Verify active session, recipient_user_id == activeAccountId,<br/>local_layout==v2_partitioned, not wipe_pending
    BG->>Lock: Resolve canonical noBackupDir via CpchatStorageDirsPlugin & acquire .partition.lock
    BG->>Lock: Open cpchat_<acct>.sqlite (must exist) & verify account_meta owner/partition_id
    BG->>Lock: Check existing message & effectiveCursor(conversationId)
    alt seq <= clearedSeq or already in LocalMessages
        BG->>Lock: Release lock & exit silently (no duplicate banner)
    else seq == cursor + 1 AND inline content present
        BG->>Lock: Load acct.<acct>.e2ee_keys + e2ee_sessions (read-only, no keygen)
        BG->>BG: E2eeService.decrypt() (in-memory advance, defer session persist)
        BG->>Lock: 1. ChatDao.upsertServerMessage(plaintext) -> COMMIT SQLite
        BG->>Lock: 2. AccountStore.writeE2eeSessions(updated) -> COMMIT Keystore
    else seq > cursor + 1 (gap) OR content_omitted == true (>4KB)
        BG->>API: GET /api/v1/conversations/:id/sync?after_seq=cursor (timeout 8s)
        API-->>BG: Ordered messages [cursor+1 .. seq]
        BG->>Lock: Decrypt & persist each message in ascending seq order (DB first, then sessions)
    end
    BG->>Lock: Resolve conversation display name, close DB, release .partition.lock
    BG->>BG: Check NotificationPolicy.shouldNotify (cached self status != dnd, sender != self)
    BG->>Tray: LocalNotificationService.showMessageNotification(title, decryptedBody, payload={a,c})
    Note over Main: Later: user taps notification or opens app
    Main->>Lock: SessionLifecycle._start() awaits .partition.lock
    Main->>Lock: E2eeManager.bootstrap() loads updated e2ee_sessions; DB already has seq=N plaintext
    Main->>Main: LocalNotificationService.coldStartTarget -> verify account -> push /conversations/:id
    Main->>API: WS connect -> syncAll(): effectiveCursor == N (no re-decrypt, 0 stubs)
```

### 2.3 FCM Data Payload Schema (`push_version >= 2`)

All FCM `data` values must be strings. Total UTF-8 payload is kept strictly **`<= 3,500 bytes`** (comfortable headroom below FCM's 4,096-byte hard limit):

| Key | Value / Example | Purpose |
|---|---|---|
| `push_schema` | `"2"` | Identifies data-only client-decrypted payload |
| `conversation_id` | UUID | Target conversation & deep-link route |
| `conversation_type` | `"direct"` \| `"group"` | Determines E2EE decryptability and title/body formatting |
| `conversation_name` | String (group name or `""`) | Fallback group title if conversation not yet in local DB |
| `message_id` | UUID | Server message ID (notification deduplication) |
| `client_msg_id` | UUIDv4 | Primary key in Drift `LocalMessages` (dedupe with WS/sync) |
| `seq` | Stringified integer (e.g. `"42"`) | Monotonic sequence number for contiguous cursor & gap detection |
| `sender_id` | UUID | E2EE `peerId` lookup & self-message suppression |
| `sender_name` | String (`"Alice"` or `"Alice (Al)"`) | Fallback title (direct) or sender prefix (group) |
| `recipient_user_id` | UUID | Per-account isolation check (`accountIdForUser(...)`) |
| `msg_type` | `"text"` \| `"image"` \| `"file"` | Media vs. text preview logic (also keep `type` alias for backwards compat) |
| `type` | `"text"` \| `"image"` \| `"file"` | Kept identical to existing schema for any legacy reader |
| `created_at` | ISO-8601 UTC timestamp | Exact timestamp for `LocalMessages` persistence |
| `content` | Raw `message.content` (E2EE envelope for direct text, plaintext for group text, `key\|caption` for media) — **omitted if total payload > 3,500 UTF-8 bytes** | Zero-round-trip offline decryption & media caption rendering |
| `content_omitted` | `"true"` (present only when `content` exceeds inline budget) | Instructs background isolate to fetch via `/sync` REST call |

*Security note:* For direct-chat text, `content` is always the `e2ee:v1:{...}` AES-256-GCM ciphertext envelope; no plaintext ever traverses FCM. Group text and media captions are already server-readable per `docs/e2ee.md:6-17`.

---

## 3. Phased Implementation Plan

Every phase is independently mergeable, keeps the build green on automated tests, and respects **Rule 0 (no APK builds)**. Recommended execution order: **Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5**. Phase 1 is strictly additive and should deploy to the backend before or alongside mobile rollout.

---

### Phase 1 — Backend Data-Only FCM Payload, 4 KB Budgeting & Push Capability Versioning

**Goal:** Enable high-priority `data`-only FCM pushes carrying encrypted envelopes and sync metadata for upgraded clients while keeping legacy `notification + data` intact for older APKs.

#### Exact Files to Create / Modify
1. **Create `backend/migrations/000010_push_capabilities.up.sql` & `.down.sql`**
   - Up:
     ```sql
     ALTER TABLE device_tokens
       ADD COLUMN push_version SMALLINT NOT NULL DEFAULT 1 CHECK (push_version >= 1);
     ```
   - Down:
     ```sql
     ALTER TABLE device_tokens DROP COLUMN push_version;
     ```
2. **Modify `backend/src/domain/devices.ts`**
   - Update `DeviceRepository.register(userId, deviceId, fcmToken, pushVersion = 1)` to upsert `push_version`.
   - Update `DeviceRepository.tokensForUser(userId)` to return `{ device_id: string; fcm_token: string; push_version: number }[]`.
3. **Modify `backend/src/http/user-routes.ts`**
   - Extend `deviceSchema` (`user-routes.ts:10-13`) with optional `push_version: z.number().int().min(1).max(10).optional().default(1)`.
   - Pass `result.data.push_version` into `devices.register(...)` (`user-routes.ts:180`).
4. **Modify `backend/src/lib/fcm.ts`**
   - Extend `PushPayload` (`fcm.ts:9-19`) with:
     - `conversationType: 'direct' | 'group'`
     - `clientMsgId: string`
     - `seq: number`
     - `createdAt: string`
     - `content: string`
   - Add a helper `buildDataOnlyMap(payload: PushPayload): Record<string, string>` that:
     - Populates all metadata keys (`push_schema: '2'`, `type`, `msg_type`, `conversation_id`, `conversation_type`, `conversation_name`, `message_id`, `client_msg_id`, `seq`, `sender_id`, `sender_name`, `recipient_user_id`, `created_at`).
     - Computes UTF-8 byte length of the serialized `data` map (keys + values + JSON overhead).
     - Includes `content: payload.content` if total UTF-8 size `<= 3500` bytes; otherwise omits `content` and sets `content_omitted: 'true'`.
   - Add `notifyDataOnly(fids: string[], payload: PushPayload): Promise<string[]>` (or branch inside `notify` via `mode: 'legacy' | 'data_only'`):
     - Sends via `this.messaging.sendEachForMulticast({ fids, data: buildDataOnlyMap(payload), android: { priority: 'high' } })` — **explicitly omitting both top-level `notification` and `android.notification`**.
     - Never logs `payload.content` or `payload.body`.
     - Reuses existing `STALE_TOKEN_CODES` pruning and structured delivery logging.
   - Keep legacy `notification + data` path intact for `push_version === 1` devices.
5. **Modify `backend/src/gateway/chat-gateway.ts`**
   - In `ChatGateway.maybeNotify()` (`chat-gateway.ts:598-650`):
     - Partition `tokens` into `v2Fids` (`push_version >= 2`) and `v1Fids` (`push_version < 2`).
     - Build the enriched `PushPayload` (adding `conversationType: isGroup ? 'group' : 'direct'`, `clientMsgId: message.client_msg_id`, `seq: message.seq`, `createdAt: message.created_at.toISOString()`, `content: message.content`).
     - Dispatch `v2Fids` with `data_only` mode and `v1Fids` with `legacy` mode (in parallel when both non-empty), combining stale FID lists for `this.ctx.devices.removeStale(stale)`.
   - In `ChatGateway.notificationPreview()` (`chat-gateway.ts:591-596`): preserve existing fallback for v1 clients, and optionally surface media captions when `message.content` contains `|caption` (matching mobile).
6. **Update `docs/api-spec.yaml`**
   - Document optional `push_version` field on `POST /api/v1/devices/fcm-token`.

#### Verification Commands (Phase 1)
```bash
cd backend && npm run typecheck && npm test
```

---

### Phase 2 — Background-Safe Storage Plugin, Safe Keystore Mode, Cross-Isolate Lock & E2EE Read-Only/Deferred-Commit API

**Goal:** Eliminate all four hidden blockers (§1.4) so the headless background isolate can safely access the exact same SQLite partition and E2EE key store as the main isolate without data corruption, key wipes, or isolate races.

#### Exact Files to Create / Modify
1. **Create in-repo Android plugin `mobile/packages/cpchat_storage_dirs/`**
   - `pubspec.yaml` (`plugin.platforms.android` package `com.cpchat.storage_dirs`, pluginClass `CpchatStorageDirsPlugin`).
   - `android/src/main/kotlin/com/cpchat/storage_dirs/CpchatStorageDirsPlugin.kt`: implements `FlutterPlugin` + `MethodCallHandler` on channel `"cpchat/storage"`, serving `getNoBackupFilesDir` (`applicationContext.noBackupFilesDir.absolutePath`) and `getCacheDir` (`applicationContext.cacheDir.absolutePath`).
   - Because it is a registered `FlutterPlugin`, `GeneratedPluginRegistrant.registerWith(engine)` attaches it to **both** `MainActivity`'s engine and `FLTFireBGExecutor`'s background engine automatically.
2. **Modify `mobile/pubspec.yaml` & `mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt`**
   - Add `cpchat_storage_dirs: { path: packages/cpchat_storage_dirs }` to `mobile/pubspec.yaml`.
   - Remove the duplicate `MethodChannel(STORAGE_CHANNEL)` registration from `MainActivity.configureFlutterEngine()` (keep `createMessageChannel()` for `"cpchat_messages"`).
3. **Modify `mobile/lib/core/storage/app_dirs.dart`**
   - Add `noBackupDirStrict()` (or parameter `allowFallback = true`) so the background isolate can require native `noBackupFilesDir` resolution (never silently falling back to `getApplicationSupportDirectory()/no_backup` on Android!).
   - Also cache the resolved canonical `noBackupDir` path in `TokenStore` (`resolved_no_backup_root`) during foreground `AppDirs.initialize()` as an extra verification/cross-check.
4. **Modify `mobile/lib/core/storage/token_store.dart`**
   - Add `factory TokenStore.forBackground({void Function(String op, String key, Object error)? onStorageError})` using `const FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false))`.
   - Keeping `FlutterSecureStorage(` strictly inside `token_store.dart` preserves `architecture_guard_test.dart:167-173`.
   - Add `readResolvedNoBackupRoot()` / `writeResolvedNoBackupRoot(String path)` helpers.
5. **Create `mobile/lib/core/account/partition_lock.dart`**
   - Cross-isolate exclusive file lock using `dart:io` `RandomAccessFile.lock(FileLock.exclusive)` on `<partitionDir>/.partition.lock` with a bounded polling/retry timeout (e.g., 5 s) and guaranteed `unlock()` + `close()` in `finally`.
   - Exposes `PartitionLock.withLock<T>(Directory partitionDir, Future<T> Function() action, {Duration timeout})`.
   - In tests (in-memory DBs with no `partitionDir`), gracefully operates as an in-process mutex.
6. **Modify `mobile/lib/core/crypto/e2ee_manager.dart`**
   - Add **`loadExistingWithoutBootstrap()`** (returns `Future<bool>`): loads existing `acct.<id>.e2ee_keys` and `acct.<id>.e2ee_sessions` into `_keys` and `_service` **without** generating keys, **without** running legacy migration, and **without** calling `/keys/me`. Returns `false` if keys are missing or unreadable.
   - Add **`decryptMessageDetached(...)`** (or `deferSessionPersist: true` flag on `plaintextFor` + explicit **`commitSessions()`** method):
     - Decrypts the envelope in memory and returns the plaintext **without** writing `acct.<id>.e2ee_sessions` yet.
     - Caller persists plaintext to Drift SQLite **first**, then calls `await e2eeManager.commitSessions()`.
     - This enforces crash-safe write ordering: a kill between DB write and Keystore write loses zero messages.
   - Add **`reloadSessionsFromDisk()`** (optional belt-and-suspenders helper if main isolate ever needs to re-read sessions).

#### Verification Commands (Phase 2)
```bash
cd mobile && flutter pub get && flutter analyze && flutter test
```

---

### Phase 3 — Mobile Headless Background Decryption, Gap-Fill / >4 KB Sync & Main-Isolate Handoff

**Goal:** Implement the background push processor that decrypts incoming E2EE payloads, handles sequence gaps and >4 KB payloads via REST sync, persists to the active account's Drift partition, and hands off to the live main isolate whenever the app is still in memory.

#### Exact Files to Create / Modify
1. **Create `mobile/lib/core/notifications/background_push_handler.dart`**
   - Define `const String kMainIsolateFcmPortName = 'cpchat_main_fcm_port';`.
   - Implement a serialized in-isolate queue (`_bgQueue`) so back-to-back pushes in the background isolate execute strictly one at a time.
   - Implement **`ParsedFcmMessage`** parsing all `push_schema == "2"` data fields (`conversationId`, `conversationType`, `conversationName`, `messageId`, `clientMsgId`, `seq`, `senderId`, `senderName`, `recipientUserId`, `msgType`, `createdAt`, `content`, `contentOmitted`).
   - Implement **`BackgroundPushHandler`** with injectable dependencies (`TokenStore`, `AppDirs`, `ApiClient` factory, `LocalNotificationService` / `MessageNotificationSink`, `E2eeService`, `PartitionLock`) so the entire flow is 100% unit-testable without live Firebase!
   - Step-by-step execution inside `handle(RemoteMessage remote)`:
     1. **Legacy OS-rendered guard:** If `remote.notification != null`, return early (OS already displayed banner; prevents duplicates on v1 payloads).
     2. **Parse payload:** If `conversationId` is empty, drop.
     3. **Main-isolate handoff check:** Lookup `IsolateNameServer.lookupPortByName(kMainIsolateFcmPortName)`.
        - If non-null: create a temporary `ReceivePort` reply port, send `{data: remote.data, replyPort: reply.sendPort}` to the main isolate, await ack with a bounded timeout (e.g., 5 s), and return! (If the send/ack times out because the main isolate is dying, fall through to headless path.)
     4. **Session & Account Isolation check (Keystore-safe):**
        - Read `accessToken`, `refreshToken`, `userId`, `activeAccountId`, `cachedUser`, and `local_layout` using `TokenStore.forBackground()` (`resetOnError: false`).
        - Verify `hasSession && activeAccountId != null && shouldHandleFcmForAccount(...)`. If not → **drop silently**.
        - Verify `senderId != userId`. If self-sent → **drop silently**.
        - Verify `local_layout == LegacyMigration.layoutVersion` (`'v2_partitioned'`). If not migrated yet → show safe fallback (`"Encrypted message"` for encrypted text / media label / plaintext for group) without touching DB or keys.
        - Check `AccountRegistry(tokenStore).pendingWipes()` does not contain `activeAccountId`. If wipe pending → **drop silently**.
     5. **Resolve Canonical Partition & Acquire `.partition.lock`:**
        - Resolve `AccountPaths` via `AppDirs.noBackupDirStrict()`.
        - If `paths == null` or `!await paths.dbFile.exists()` → do **not** create a new DB; fall back safely to notification display (`"Encrypted message"` for E2EE, label for media, plaintext for group).
        - Acquire `PartitionLock.withLock(paths.partitionDir, ...)` (timeout 5 s).
     6. **Read-Only Partition Integrity Verification:**
        - Open `AppDatabase.forFile(paths.dbFile)` (in `try { ... } finally { await db.close(); }`).
        - Assert `db.readMeta('owner_user_id') == userId` and `db.readMeta('partition_id') == await accountStore.readPartitionId()`. On mismatch → abort DB/E2EE access immediately and drop silently.
     7. **Deduplication & Watermark Check:**
        - Read `conv = await dao.conversation(conversationId)`.
        - If `seq != null && conv != null && seq <= conv.clearedSeq` → drop silently (message predates cleared watermark).
        - If `clientMsgId != null`: check `existing = await dao.message(clientMsgId)`.
          - If `existing != null` and already readable (`!isEncryptedContent(existing.content) && existing.content != undecryptableContent`): message was already processed (e.g. arrived over WS right before app kill or FCM redelivery) → **do not re-decrypt and do not show a duplicate notification** (return cleanly).
     8. **Decrypt & Persist (Contiguous Ordering + Crash-Safe Commit):**
        - Determine `isGroup = parsed.conversationType == 'group' || conv?.type == 'group'`.
        - Compute `cursor = await dao.effectiveCursor(conversationId)`.
        - **Fast Path (Zero network round-trip):** `parsed.seq == cursor + 1` and `!parsed.contentOmitted` and `parsed.content != null`:
          - If `!isGroup && parsed.msgType == 'text' && isEncryptedContent(parsed.content)`:
            - Load existing keys/sessions via `e2eeManager.loadExistingWithoutBootstrap()`. If `false` → fallback body `"Encrypted message"`.
            - Decrypt via `e2eeManager.plaintextFor(..., deferSessionPersist: true)`.
            - If decryption succeeds:
              1. `await dao.upsertServerMessage(decryptedMessage, status: 'sent')` (**SQLite first!**)
              2. `await e2eeManager.commitSessions()` (**Keystore second!**)
            - If decryption fails: leave ratchet & DB untouched; fallback body `"Encrypted message"`.
          - Else (group text or media):
            - Persist directly via `await dao.upsertServerMessage(message, status: 'sent')` (no ratchet involved).
        - **Gap-Fill / >4 KB Slow Path (Authenticated REST Sync):** `parsed.seq != null && (parsed.seq! > cursor + 1 || parsed.contentOmitted || parsed.content == null)`:
          - Build short-timeout `ApiClient` (`connectTimeout: 5s, receiveTimeout: 8s`, `deviceId: await tokenStore.readDeviceId()`).
          - Note: Since `IsolateNameServer` confirmed the main isolate is dead and `.partition.lock` is held, token refresh inside `ApiClient` cannot race the main isolate.
          - Fetch `GET /api/v1/conversations/:id/sync?after_seq={cursor}&limit={min(50, max(1, seq - cursor))}` (paginated up to e.g. 2 pages / 100 messages max within budget).
          - Apply `result.clearedSeq` if `> 0`.
          - Iterate strictly in ascending `seq` order (`msg.seq == runningCursor + 1`): decrypt each direct text message (defer session persist), write to SQLite via `dao.upsertServerMessage`, then commit sessions via `e2eeManager.commitSessions()` after each contiguous batch.
          - Capture the decrypted `Message` matching `parsed.clientMsgId` / `parsed.seq` for the notification body.
          - If REST sync fails (offline / 401 / timeout / gap too large): do **not** decrypt out of order and do **not** advance the ratchet; fall back to `"Encrypted message"` (direct text), media label (image/file), or `"New message"`.
     9. **Resolve Display Title & Apply Policy:**
        - Resolve `ConversationNames` from `conv` (using the same `_directPeerLabel` logic as foreground `providers.dart:402-422`), falling back to `parsed.conversationName` (group) or `parsed.senderName` (direct).
        - Close `db` and release `.partition.lock` **before** calling notification plugin.
        - Check `NotificationPolicy.shouldNotify(senderId: parsed.senderId, selfId: userId, selfStatus: cachedUser?.status, appResumed: false, activeConversationId: null, conversationId: parsed.conversationId)`. If suppressed (e.g. DND) → return without displaying.
        - Format via `NotificationPolicy.format(isGroup: isGroup, conversationName: ..., senderName: parsed.senderName, type: parsed.msgType, content: displayContent)`.
     10. **Render Notification:**
         - Initialize `LocalNotificationService(checkLaunchDetails: false)` and call `showMessageNotification(conversationId: ..., title: rendered.title, body: rendered.body, messageId: parsed.messageId, accountId: activeAccountId)`.
2. **Modify `mobile/lib/core/notifications/fcm_service.dart`**
   - Update `firebaseMessagingBackgroundHandler(RemoteMessage message)` (`fcm_service.dart:95-110`) to call `WidgetsFlutterBinding.ensureInitialized()` (ensures platform channels & `DartPluginRegistrant` are ready in the background isolate), `await Firebase.initializeApp()`, and delegate to `BackgroundPushHandler.handle(message)`.
   - Keep `shouldHandleFcmForAccount()` and update `resolveHeadlessFcmDisplay()` (or mark as superseded by `BackgroundPushHandler` while keeping unit-test coverage for account isolation).

#### Verification Commands (Phase 3)
```bash
cd mobile && flutter analyze && flutter test
```

---

### Phase 4 — Notification UX Parity, Foreground FCM Decryption, Media Captions & App Resume Sync Coordination

**Goal:** Guarantee 100% visual, policy, media, deduplication, and tap-routing parity across foreground, minimized, and terminated states, and wire the `.partition.lock` + `IsolateNameServer` bridge in the main isolate.

#### Exact Files to Modify
1. **Modify `mobile/lib/core/notifications/notification_policy.dart`**
   - Update `NotificationPolicy.preview({required String type, required String content})` (`notification_policy.dart:32-40`):
     - Import `splitMediaContent` from `../media/media_service.dart`.
     - For `type == 'image'`: extract `caption = splitMediaContent(content).caption?.trim()`. Return `caption != null && caption.isNotEmpty ? 'Photo: $caption' : 'Sent an image'` (preserves existing `'Sent an image'` when no caption is present, matching existing unit test `notifications_test.dart:153`).
     - For `type == 'file'`: extract `caption = splitMediaContent(content).caption?.trim()`. Return `caption != null && caption.isNotEmpty ? 'File: $caption' : 'Sent a file'` (preserves `'Sent a file'` when uncaptioned, matching `notifications_test.dart:154`).
     - For `type == 'text'`: if `isEncryptedContent(content) || content == undecryptableContent`, return `'Encrypted message'`; else trimmed text (or `'New message'` if empty).
   - Extract shared `formatDirectPeerLabel(String? name, String? nickname)` helper so `providers.dart` and `background_push_handler.dart` produce identical `"Name (nickname)"` titles.
2. **Modify `mobile/lib/core/notifications/local_notification_service.dart`**
   - Add optional parameter `bool checkLaunchDetails = true` to `initialize({bool checkLaunchDetails = true})` (`local_notification_service.dart:118`) so headless background invocations skip `getNotificationAppLaunchDetails()`.
3. **Modify `mobile/lib/core/notifications/push_registration.dart` & `mobile/lib/core/network/api_client.dart`**
   - Update `ApiClient.registerFcmToken(String fid, {int pushVersion = 2})` (`api_client.dart:652-661`) to include `'push_version': pushVersion` in the `POST /api/v1/devices/fcm-token` request body.
   - Update `PushRegistration` to re-register once after upgrading from v1 → v2 (already happens naturally on cold-start `PushRegistration.start()`, which runs on every app launch!).
4. **Modify `mobile/lib/core/providers.dart`**
   - In `SessionLifecycle._start()` (`providers.dart:496-570`):
     - Wrap step 1 (`PartitionGuard.verify(db)`) + step 2 (`e2ee.bootstrap()`) in `PartitionLock.withLock(paths.partitionDir, ...)` so if a background isolate was mid-decrypt as the user launched the app, the main isolate cleanly awaits completion before loading `acct.<id>.e2ee_sessions` and opening `AppDatabase`!
   - Expose a `handleMainIsolateFcmPush(Map<String, dynamic> data)` helper/provider (e.g. on `ChatSocket` or a small `FcmMessageIngestor` provider) that:
     - Verifies `accountScopeProvider` matches `recipient_user_id`.
     - If `seq == cursor + 1` and inline `content` is present: runs through `ChatSocket`'s serialized `_persistServerMessage(msg)` + `_emitIncoming(msg)` (which decrypts via the live `E2eeManager`, writes to `ChatDao`, and triggers `MessageNotifier.onLiveMessage` with `RecentIdSet` deduplication and active-chat suppression!).
     - If `seq > cursor + 1` or `content_omitted == "true"`: triggers `ChatSocket.syncAll()` (or `_syncConversation`) and notifies via `MessageNotifier` for the target message if newly inserted.
5. **Modify `mobile/lib/main.dart`**
   - Register the `ReceivePort` under `IsolateNameServer.registerPortWithName(port.sendPort, kMainIsolateFcmPortName)` in `_CpChatAppState.initState()` (removing any stale mapping first) and remove/close it in `dispose()`.
   - Forward messages received on that `ReceivePort` to `handleMainIsolateFcmPush(data)`, then send completion ack on `replyPort`.
   - Update `_onForegroundMessage(RemoteMessage message)` (`main.dart:274-293`) to route `push_schema == "2"` data-only messages through `handleMainIsolateFcmPush(message.data)` instead of the old `notificationContentFromFcm` stub (retaining legacy fallback if `message.notification != null`).
   - In `_openConversation(String conversationId)` (`main.dart:304-308`): avoid pushing a duplicate route if `activeConversationIdProvider == conversationId`.

#### Verification Commands (Phase 4)
```bash
cd mobile && flutter analyze && flutter test
```

---

### Phase 5 — Comprehensive Automated Tests & Documentation Updates

**Goal:** Lock in every requirement, edge case, and architectural invariant with automated tests across backend and mobile, and update architecture/E2EE docs.

#### Exact Files to Create / Modify
1. **Backend tests (`backend/test/notifications.test.ts`):**
   - Assert `push_version: 2` device receives high-priority `data`-only payload with `push_schema: '2'`, `conversation_type`, `client_msg_id`, `seq`, `created_at`, `content` (exact E2EE ciphertext for direct text, plaintext for group text), and **no `notification` block**.
   - Assert `push_version: 1` (legacy) device still receives `notification + data` with `"Encrypted message"` for direct E2EE text.
   - Assert oversized ciphertext (>3,500 UTF-8 bytes) omits `content` and sets `content_omitted: 'true'` while total `data` byte length stays `< 4096`.
   - Assert mixed-version user (one v1 device + one v2 device) dispatches each format to the respective FID and prunes stale FIDs from both.
   - Assert `POST /api/v1/devices/fcm-token` persists `push_version` (defaults to `1` when omitted, stores `2` when provided).
2. **Mobile unit & integration tests:**
   - **Create `mobile/test/background_push_decrypt_test.dart`:**
     - End-to-end terminated E2EE flow: Alice encrypts direct message → v2 `data`-only `RemoteMessage` → `BackgroundPushHandler.handle()` → decrypts with Bob's `acct.<bob>.e2ee_keys`, persists plaintext into Bob's file-backed Drift DB, persists updated `acct.<bob>.e2ee_sessions`, raises local notification with **real plaintext body**, title = Alice, channel `cpchat_messages`, payload `{"a":"<bobAcct>","c":"<convId>"}`.
     - **Double-decryption / resume sync safety:** Immediately after `BackgroundPushHandler` processes `seq=1`, boot a fresh `E2eeManager` + `ChatSocket` (simulating app open) and replay `seq=1` via `storeServerMessages` / REST sync + send `seq=2` → assert `seq=1` is NOT re-decrypted, stays readable plaintext, and `seq=2` decrypts cleanly with zero ratchet errors!
     - **Crash-safety test:** Simulate failure persisting `e2ee_sessions` after SQLite write → verify `seq=1` remains readable in SQLite and `seq=2` still decrypts via forward ratchet skip.
     - **Gap / out-of-order test:** Local cursor at `seq=1`, push arrives for `seq=3` → verifies handler calls `/sync?after_seq=1`, decrypts `seq=2` and `seq=3` in order, persists both, and notifies with `seq=3`'s plaintext. Also tests offline gap (sync fails) → verifies ratchet is **not** advanced past `seq=2` and safe `"Encrypted message"` fallback is shown.
     - **>4 KB `content_omitted: 'true'` test:** Verifies handler calls `/sync?after_seq=cursor`, decrypts oversized ciphertext, persists, and displays plaintext.
     - **Per-account isolation tests:** (a) Logged out → dropped; (b) User B signed in, push for User A → dropped, A's DB untouched; (c) `wipe_pending.<acct>` active → dropped; (d) `account_meta` owner mismatch → dropped; (e) unmigrated legacy layout → fallback shown without mutating DB/keys.
     - **DND & self-message suppression:** Cached user `status == 'dnd'` or `sender_id == selfId` → no notification shown.
     - **Duplicate push delivery:** Push for an already-persisted readable `client_msg_id` → no re-decryption, no second notification.
     - **Media & group messages:** Image without caption (`"Sent an image"`), image with caption (`"Photo: sunset"`), file without caption (`"Sent a file"`), file with caption (`"File: report.pdf"`), group plaintext (`title: "Weekend Squad"`, `body: "Bob: hi all"`).
     - **Unrecoverable decryption / locked keystore:** Missing keys, corrupted ciphertext, or `PlatformException` from `TokenStore.forBackground()` → never wipes secure storage (`resetOnError: false`), falls back cleanly to `"Encrypted message"`.
     - **Lock contention test (`PartitionLock`):** Verifies concurrent acquire blocks until first holder releases.
   - **Update `mobile/test/notifications_test.dart`:** Add caption preview tests for `NotificationPolicy.preview` and verify `PushRegistration` sends `push_version: 2`.
   - **Verify `mobile/test/architecture_guard_test.dart`:** Confirm banned-API static guards still pass (`FlutterSecureStorage(` only in `token_store.dart`, `getTemporaryDirectory` only in `app_dirs.dart`, no `driftDatabase(`).
3. **Update docs:**
   - `docs/e2ee.md`: document background-isolate E2EE decryption, crash-safe DB-before-sessions commit order, and gap-fill sync invariant.
   - `docs/architecture.md`: update FCM flow from `notification+data` to `push_version=2` high-priority `data`-only with `IsolateNameServer` handoff and `.partition.lock`.

#### Verification Commands (Phase 5 — Full Gate)
```bash
cd backend && npm run typecheck && npm test
cd mobile && flutter analyze && flutter test
```

---

## 4. Edge Cases & Failure Modes Matrix

| # | Edge Case / Failure Mode | Root Risk | Explicit Mitigation | Expected Outcome |
|---|---|---|---|---|
| 1 | **App opens after background decrypt & syncs same message (Double-Decryption)** | Re-decrypting an already-consumed symmetric ratchet index throws `chain_position_ahead` and overwrites bubble with `"Unable to decrypt this message"`. | Background isolate persists decrypted plaintext into `LocalMessages` (`client_msg_id` PK, `seq`). On app resume, `ChatDao.effectiveCursor()` is already `>= seq` and `ChatSocket._alreadyReadable()` (`ws_client.dart:502-511`) returns `true`. | Message renders immediately from SQLite as plaintext; sync skips re-decryption; subsequent messages (`seq+1`) decrypt normally. |
| 2 | **Process killed mid-background-decrypt (Crash between DB write and Keystore write)** | If `e2ee_sessions` updated before SQLite, kill loses plaintext permanently. | **Commit SQLite FIRST, then commit `acct.<id>.e2ee_sessions`.** If killed between the two, message `N` is already plaintext in SQLite (`_alreadyReadable` skips it) and message `N+1` decrypts because `_decryptWith` skips the symmetric chain forward from `i` to `i+1`. | Zero message loss under mid-handler OS kill. |
| 3 | **Out-of-order FCM delivery or dropped earlier push (`seq > cursor + 1`)** | Decrypting `seq=12` before `seq=11` advances the symmetric ratchet (which has no skipped-key storage) past `seq=11` AND bumps `localMaxSeq` to `12`, permanently losing `seq=11`. | Check `seq == cursor + 1`. If `seq > cursor + 1`, run authenticated `GET /conversations/:id/sync?after_seq={cursor}` to fetch, decrypt, and persist `cursor+1..seq` strictly in ascending order. If offline/timeout, abort decrypt without advancing ratchet and show `"Encrypted message"` fallback. | Zero skipped messages; ratchet stays strictly contiguous. |
| 4 | **Main isolate & background isolate overlap (minimized WS drop or user launches app mid-push)** | Concurrent writes to SQLite, stale in-memory `E2eeManager` overwriting updated `e2ee_sessions`, or duplicate refresh-token rotation triggering token-family revocation. | (a) When main isolate is alive, `IsolateNameServer` (`'cpchat_main_fcm_port'`) routes the push directly to the main isolate (single owner). (b) When main isolate is dead/booting, exclusive `.partition.lock` serializes background decrypt against `SessionLifecycle._start()`. | Zero ratchet clobbering, zero SQLITE_BUSY corruption, zero refresh-token reuse revocation. |
| 5 | **Wrong storage path in headless isolate (`MainActivity` not running)** | `MainActivity`'s `MethodChannel('cpchat/storage')` throws `MissingPluginException` in `FLTFireBGExecutor`; `AppDirs` would fall back to `files/no_backup` instead of `no_backup`, splitting the DB. | Move `cpchat/storage` into local `FlutterPlugin` (`packages/cpchat_storage_dirs`) auto-registered by `GeneratedPluginRegistrant` on **all** Flutter engines + enforce `noBackupDirStrict()` + require existing `dbFile`. | Both isolates always open the exact same `<noBackupFilesDir>/accounts/<id>/cpchat_<id>.sqlite`. |
| 6 | **Per-account isolation (logged out, switched to User B, or L2 wipe pending)** | User B seeing User A's decrypted notification or A's keys being touched while B is signed in. | Check `TokenStore.forBackground()` session presence, `accountIdForUser(recipientUserId) == activeAccountId`, not in `AccountRegistry.pendingWipes()`, and read-only `account_meta` `owner_user_id` + `partition_id` match before any decrypt/display. | Foreign, signed-out, or wiping-account pushes are silently dropped; zero cross-account leakage. |
| 7 | **FCM 4 KB payload overflow (large text or X3DH initiation envelope)** | FCM rejects payloads `> 4096 bytes` with `invalid-argument` (which `STALE_TOKEN_CODES` would mistakenly prune as a stale token!). | Backend measures exact UTF-8 byte length of `data`; if `> 3500` bytes, omits `content` and sets `content_omitted: "true"`. Background isolate fetches the full ciphertext via `GET /conversations/:id/sync?after_seq={cursor}` and decrypts locally. | Large messages deliver reliably; FID is never falsely pruned. |
| 8 | **Locked screen (AFU) vs. Direct Boot before first unlock (BFU) / Keystore error** | Default `TokenStore` has `resetOnError: true`, which would wipe all keys & tokens on a transient Keystore failure in Direct Boot. | (a) Normal locked screen (AFU): Keystore is unlocked (keys do not require user auth), so decryption succeeds normally. (b) Direct Boot / Keystore error: `TokenStore.forBackground()` sets **`resetOnError: false`** so errors return `null` without wiping storage; push fails safely (dropped if auth unreadable, or `"Encrypted message"` if keys unreadable). | Full decryption on locked screen (AFU); zero destructive key wipes on Keystore errors/BFU. |
| 9 | **Duplicate notifications (WS + FCM race or FCM redelivery)** | Same message triggers two tray banners. | (a) Main-isolate handoff shares `MessageNotifier._recent` (`RecentIdSet`, 60 s window keyed by `message.id`). (b) Headless path checks `dao.message(clientMsgId)` — if already persisted & readable, suppresses notification. (c) Deterministic `notificationIdFor(conversationId, accountId)` + `tag: accountId` replaces rather than stacks duplicates. | At most one notification per message. |
| 10 | **Media / attachment messages (with and without captions)** | Showing raw `objectKey` or `"Encrypted message"` for photos/files. | `NotificationPolicy.preview()` parses `splitMediaContent(content)`: image → `"Photo: <caption>"` or `"Sent an image"`; file → `"File: <caption>"` or `"Sent a file"`. Identical across foreground and terminated paths. | Clean, consistent media labels and captions everywhere. |
| 11 | **Group chat messages** | Trying to E2EE-decrypt plaintext group text or missing sender prefix. | `conversation_type == "group"` skips E2EE decryption, persists plaintext to `LocalMessages`, formats via `NotificationPolicy.format(isGroup: true)` → `title: groupName`, `body: "Sender: <text>"`. | Exact parity with foreground group notifications. |
| 12 | **Brand-new conversation (first message while terminated)** | `LocalConversations` row does not exist yet in SQLite. | `LocalMessages` has no FK to `LocalConversations`, so `seq == 1` (`cursor == 0`) decrypts (using `peerId = senderId`) and persists into `LocalMessages`. Title falls back to `sender_name` / `conversation_name` from FCM `data`. On app open, `ChatDao._summaryPreview` finds the decrypted row immediately. | First message in a new chat decrypts and displays seamlessly. |
| 13 | **Unmigrated legacy install receives push before first foreground launch** | `local_layout != 'v2_partitioned'`; running `PartitionGuard` in background could misclassify state. | Background handler checks `local_layout == 'v2_partitioned'` and never runs migration or key generation. Falls back to `"Encrypted message"` (direct) / plaintext (group) until main app completes `LegacyMigration`. | Safe upgrade with zero migration races. |
| 14 | **Backward compatibility with older installed APKs** | Old APKs (`fcm_service.dart:30`) ignore `conversation_name`/`msg_type` on data-only pushes and show `"New message"` for every push. | Additive `device_tokens.push_version` column (default `1`). Only `push_version >= 2` devices receive `data`-only payloads; v1 devices keep receiving `notification + data`. | Zero regression for users who haven't updated yet. |
| 15 | **Android Doze / High-Priority FCM Quota** | Android throttles apps that receive `priority: 'high'` data-only pushes without displaying a visible notification. | Backend already filters out online and `dnd` users before sending FCM. Whenever the background handler accepts a push for the active non-DND user, it **always** posts a local notification (either decrypted plaintext or `"Encrypted message"` fallback). | App remains in high-priority FCM bucket; reliable Doze delivery. |

---

## 5. Testing & Real-Device Verification Plan

### 5.1 Automated Test Suites (Required CI / Local Gates)

Per **Rule 0 (`AGENTS.MD`)**, no APK or App Bundle is built during automated verification.

```bash
# Backend typecheck & full integration/unit suite
cd backend && npm run typecheck && npm test

# Mobile static analysis & full unit/widget/architecture-guard suite
cd mobile && flutter analyze && flutter test
```

Targeted test files to run and pass:
- `backend/test/notifications.test.ts` (v1 vs v2 payload shapes, >3,500 B `content_omitted`, mixed-version users, stale FID pruning, `push_version` registration).
- `mobile/test/background_push_decrypt_test.dart` (new: full E2EE terminated decrypt, resume sync double-decrypt safety, crash-safe ordering, gap-fill sync, >4 KB sync, multi-account isolation, DND, duplicates, media captions, locked keystore `resetOnError: false`, `PartitionLock`).
- `mobile/test/notifications_test.dart` (media caption previews, `PushRegistration` v2 capability, `NotificationTapTarget` `{a,c}` routing).
- `mobile/test/e2ee_delivery_test.dart` & `mobile/test/account_isolation_test.dart` (existing E2EE once-only and multi-account invariants).
- `mobile/test/architecture_guard_test.dart` (static enforcement that `FlutterSecureStorage(`, `getTemporaryDirectory`, `driftDatabase(`, `DefaultCacheManager` remain strictly encapsulated).

### 5.2 Real-Device Manual QA Matrix (Physical Android Devices)

**Prerequisites:**
- Two test accounts: **Alice** (sender) and **Bob** (recipient, `status != 'dnd'`), plus a third account **Charlie** for multi-account switching and group chat testing.
- Physical Android device(s) (e.g., Android 13/14 with notification permission granted; optionally Android 11/12) running the updated app via `flutter run -d android` (or an owner/CI-produced build — never an agent-built APK).
- Backend `gateway` container running with FCM enabled (`docker logs cp-chat-gateway-1 | grep "FCM initialized"`).
- Verify `device_tokens` shows `push_version = 2` for Bob's device:
  ```bash
  docker exec cp-chat-postgres-1 psql -U cpchat -d cpchat -c \
    "SELECT u.name, u.status, dt.device_id, dt.push_version, left(dt.fcm_token, 20) AS fid, dt.updated_at
     FROM users u JOIN device_tokens dt ON dt.user_id = u.id ORDER BY dt.updated_at DESC;"
  ```

| ID | App State (Bob) | Test Action (Alice → Bob) | Expected Notification & Post-Open Behavior |
|---|---|---|---|
| **M-1** | **Foreground** (on Conversations list) | Alice sends 1:1 E2EE text `"Hello foreground"` | Local notification appears with title = `Alice`, body = `"Hello foreground"` (via WS). |
| **M-2** | **Foreground** (inside Alice's chat) | Alice sends 1:1 E2EE text `"Suppress me"` | **No** tray notification raised (`activeConversationId` suppression). Message renders in chat. |
| **M-3** | **Minimized** (Home button, process alive) | Alice sends 1:1 E2EE text `"Hello minimized"` | Notification appears with title = `Alice`, body = `"Hello minimized"`. Tapping opens Alice's chat with no duplicate bubble. |
| **M-4** | **Terminated** (swiped away from Recents; confirm `ws disconnected` in gateway logs) | Alice sends 1:1 E2EE text `"Secret lunch at 12?"` | High-priority data-only FCM wakes headless isolate → tray notification displays title = `Alice`, body = **`"Secret lunch at 12?"`** (NOT `"Encrypted message"`). Tap notification → cold-starts directly into Alice's chat showing `"Secret lunch at 12?"` cleanly with **0** `"Unable to decrypt"` stubs. |
| **M-5** | **Terminated** (screen locked, AFU) | Alice sends 3 rapid E2EE messages `"One"`, `"Two"`, `"Three"` | Each notification displays real decrypted text in order. Opening the app shows all 3 messages intact; Alice sends `"Four"` while Bob is open → decrypts cleanly (proving ratchet stayed synchronized). |
| **M-6** | **Terminated** (new X3DH initiation) | First-ever 1:1 message from Charlie to Bob while Bob is terminated | Background isolate derives responder X3DH session, decrypts, persists, and displays Charlie's plaintext. Opening app shows Charlie's conversation + plaintext preview immediately. |
| **M-7** | **Terminated** (oversized >4 KB message) | Alice sends a ~3,500-char 1:1 E2EE message (envelope > 4 KB) | Backend sets `content_omitted: "true"`. Background isolate fetches via `/sync`, decrypts, persists, and displays actual message preview. |
| **M-8** | **Terminated** (media messages) | Alice sends (a) image without caption, (b) image with caption `"Beach!"`, (c) PDF file without caption, (d) file with caption `"Invoice"` | Tray displays: (a) `"Sent an image"`, (b) `"Photo: Beach!"`, (c) `"Sent a file"`, (d) `"File: Invoice"`. |
| **M-9** | **Terminated** (group chat) | Alice sends `"Meeting at 3"` in group `"Project Alpha"` | Tray displays title = `"Project Alpha"`, body = `"Alice: Meeting at 3"`. Tap opens `"Project Alpha"`. |
| **M-10** | **Terminated + Force-Stopped** (`Settings → Force Stop`) | Alice sends `"After force stop"` | Note Android OS behavior: force-stopped apps do not receive broadcasts/FCM until reopened. After reopening, `syncAll()` pulls and decrypts `"After force stop"` cleanly. *(Documented OS constraint; normal swipe-away from recents IS M-4 and must work.)* |
| **M-11** | **Account Switch (Terminated)** | Bob logs out → Charlie logs in → Charlie swipes app away → stale/simulated push targeting Bob arrives | Background handler verifies `recipient_user_id != Charlie`, drops silently; **no** notification shown; Bob's partition untouched. |
| **M-12** | **DND (Terminated)** | Bob sets status to `dnd`, swipes app away → Alice sends `"Quiet please"` | Backend skips FCM (and client policy double-checks cached `dnd` status). No notification raised; message appears cleanly when Bob opens app. |

### 5.3 Diagnostic Logcat & Gateway Checks During QA

```bash
# Watch gateway FCM dispatch (verify data-only multicast accepted, never logs body)
docker logs -f --tail 50 cp-chat-gateway-1 2>&1 | grep -iE "ws disconnected|FCM|push|ws send accepted"

# Watch Android headless isolate execution, plugin resolution, and tray posting
adb logcat -v time | grep -iE "FLTFireMsgReceiver|FLTFireMsgService|FLTFireBGExecutor|CpchatStorageDirs|cpchat_messages|BackgroundPushHandler|E2EE"
```

Verify in logcat:
- **Zero** plaintext message content or E2EE private keys ever printed in `adb logcat` or gateway logs.
- **Zero** `MissingPluginException` for `cpchat/storage` in `FLTFireBGExecutor`.
- **Zero** `E2eeException: predates the current chain position` errors when opening the app after terminated notifications.
