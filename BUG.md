# Android Terminated Push Notification Failure — Root-Cause Analysis

## Problem Statement

On Android (reproduced across Samsung, Poco, and a stock Android Emulator with all notification permissions granted):

1. **App in foreground (open):** Notifications **work**.
2. **App in background (minimized, not swiped away from recents):** Notifications **work**.
3. **App terminated / swiped away from recents:** Notifications **do not appear at all**.

---

## Executive Summary

**Foreground and minimized notifications are not coming from FCM at all** — they are delivered over the live **WebSocket** and rendered locally by `flutter_local_notifications`. When the app is swiped away / terminated, the OS kills the WebSocket, leaving **FCM** as the sole delivery path — and the FCM pipeline is broken at **three independent failure points**:

1. **Mobile code bug (affects every device & emulator):** `FcmService.currentToken()` calls `FirebaseMessaging.instance.register()` (Firebase Messaging Android SDK `26.0.2` FID API), which **unconditionally throws `IllegalStateException: API disabled`** unless `<meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />` is present in `AndroidManifest.xml`. That meta-data entry is missing, `FcmService.currentToken()` catches and swallows the exception, and **`POST /api/v1/devices/fcm-token` is never called** (`device_tokens` has **0 rows** in PostgreSQL).
2. **Backend runtime deployment config:** The running `cp-chat-gateway-1` container boots with **`FCM disabled`** because root `.env` leaves `FCM_CREDENTIALS_FILE` empty and defines no `FIREBASE_*` variables (credentials were placed in `backend/.env.local` using a host path that Docker Compose neither reads nor mounts).
3. **Stale local APK artifacts (if testing those builds):** Both APKs in `mobile/build/app/outputs/apk/` were built on `2026-11-24` (before `google-services.json` and commit `8fc83be` on `2026-11-25`) and contain **no compiled Google Services resources** (`google_app_id` / `project_id` absent), causing `Firebase.initializeApp()` to fail before registration is even attempted.

---

## 1. End-to-End Flow Summary

### A. Foreground & Minimized (Not Swiped Away) — WebSocket + Local Notifications (NOT FCM)

1. **Sender → Gateway:** Sender writes a `send` frame over WebSocket. `ChatGateway.handleSend` → `deliverStoredInner` persists the message and fans out to every other member via `route(memberId, messageEvent)` followed by `maybeNotify(...)` (`backend/src/gateway/chat-gateway.ts:526-533`).
2. **Why WebSocket still delivers when minimized:** `didChangeAppLifecycleState` in `mobile/lib/main.dart:214-217` only updates `appLifecycleProvider`; **nothing disconnects `ChatSocket` on background/minimize**. `ChatSocket` keeps the TCP socket alive with a 25 s ping (`mobile/lib/core/network/ws_client.dart:59`, `849-854`).
3. **Gateway skips FCM while minimized:** `ChatGateway.hasConnectedDevice()` finds the open WebSocket (or Redis `conn:{user}:{device}` key), so `maybeNotify()` exits early (`backend/src/gateway/chat-gateway.ts:608-611`, `659-664`).
4. **Mobile renders local tray notification:**
   - `ChatSocket._handleMessage` persists + decrypts the message and calls `onIncomingMessage` (`mobile/lib/core/network/ws_client.dart:623-653`).
   - `mobile/lib/core/providers.dart:108-112` routes that callback to `MessageNotifier.onLiveMessage` (`mobile/lib/core/notifications/message_notifier.dart:37-57`).
   - `NotificationPolicy.shouldNotify` (`mobile/lib/core/notifications/notification_policy.dart:14-26`) suppresses only own messages, `dnd`, or `appResumed && activeConversationId == conversationId`. When minimized (`appResumed == false`) or foregrounded elsewhere, it calls `LocalNotificationService.showMessageNotification` (`mobile/lib/core/notifications/local_notification_service.dart:94-117`) on channel `cpchat_messages`.

### B. Terminated (Swiped Away) — Depends 100% on FCM (Currently Broken End-to-End)

1. **OS kills app process:** WebSocket closes (`ws disconnected` in gateway logs) and `ChatGateway.onClose` unregisters `conn:{user}:{device}` (`backend/src/gateway/chat-gateway.ts:255-270`).
2. **Gateway push gate (`maybeNotify`):**
   - Checks `this.notifications.enabled` (`backend/src/gateway/chat-gateway.ts:604`) → **FAILS HERE TODAY** (credentials empty in running gateway container).
   - Checks `hasConnectedDevice(userId)` (`backend/src/gateway/chat-gateway.ts:608`).
   - Checks `recipient?.status === 'dnd'` (`backend/src/gateway/chat-gateway.ts:616-620`).
   - Queries `device_tokens` via `DeviceRepository.tokensForUser` (`backend/src/gateway/chat-gateway.ts:622-626`, `backend/src/domain/devices.ts:42-48`) → **ALSO FAILS HERE TODAY** (`device_tokens` has **0 rows** because mobile registration always throws).
3. **Intended FCM payload (`backend/src/lib/fcm.ts:90-110`):**
   - Sends **both** `notification: { title, body }` **and** `data: { type, conversation_id, message_id, sender_id, sender_name, conversation_name }`, addressed via `fids` (`firebase-admin` v14 `FidMulticastMessage`), with `android: { priority: 'high', notification: { channelId: 'cpchat_messages', sound: 'default' } }`.
4. **Intended Android terminated handling:**
   - Because the backend sends a `notification` block, Android's `FirebaseMessagingService` natively displays the tray notification on channel `cpchat_messages` (matching `mobile/android/app/src/main/AndroidManifest.xml:50-52`) without needing the Dart isolate to render it.
   - `FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler)` is registered before `runApp` (`mobile/lib/main.dart:32`) as a top-level `@pragma('vm:entry-point')` function (`mobile/lib/core/notifications/fcm_service.dart:35-51`). It calls `await Firebase.initializeApp()`, exits early if `message.notification != null` (to avoid duplicate banners), and for **data-only** pushes creates a standalone `LocalNotificationService()` (no Riverpod/Drift/E2EE/`NotificationPolicy` dependency; `getNotificationAppLaunchDetails()` safely guards `mainActivity != null`) and displays it.
   - **R8/ProGuard check:** `mobile/android/app/proguard-rules.pro:14-25` keeps `io.flutter.plugins.firebase.**`, `io.flutter.embedding.**`, and `@SerializedName`; `@pragma('vm:entry-point')` prevents Dart AOT tree-shaking of `firebaseMessagingBackgroundHandler`; `@mipmap/ic_launcher` is referenced in `AndroidManifest.xml` so `isShrinkResources = true` retains it. R8 is **not** stripping the background handler.

---

## 2. Confirmed Root Cause(s) (Ranked by Certainty)

### Confirmed from Code + Bytecode + Live Runtime State

#### 1. `[CONFIRMED — Mobile Code Bug]` Missing `firebase_messaging_installation_id_enabled` Manifest Meta-Data Breaks FID Registration on ALL Devices & Emulators
- **Where:** `mobile/lib/core/notifications/fcm_service.dart:90-100`, `mobile/android/app/src/main/AndroidManifest.xml:9-53`, `mobile/pubspec.yaml:46` (`firebase_messaging: ^17.1.0` → Android `com.google.firebase:firebase-messaging:26.0.2`).
- **Mechanism:** `FcmService.currentToken()` calls `FirebaseMessaging.instance.register()`. Disassembling `com.google.firebase.messaging.FirebaseMessaging.register()` in `firebase-messaging-26.0.2.aar` confirms it checks `GmsRegistrationClient.isV1RegistrationEnabled()`, which reads `<meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />` from `AndroidManifest.xml`. Because that meta-data is absent, `register()` unconditionally fails with:
  ```text
  IllegalStateException: API disabled. Please enable it by adding
  <meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />
  to your app's manifest.
  ```
- **Why it is silent:** `FcmService.currentToken()` catches the error, calls `debugPrint(...)` (not `AppLogger`), and returns `null` (`mobile/lib/core/notifications/fcm_service.dart:96-99`). `PushRegistration._register(null)` is a no-op (`mobile/lib/core/notifications/push_registration.dart:49-50`).
- **Live proof:** PostgreSQL `device_tokens` has **0 rows**, and `cp-chat-api-1` logs show **0 calls** to `POST /api/v1/devices/fcm-token`.
- **Why minimized works / terminated fails:** Minimized notifications use WebSocket + local notifications and never need a registered FCM token; terminated notifications require a `device_tokens` row.

#### 2. `[CONFIRMED — Backend Live Deployment Config]` Running `cp-chat-gateway-1` Has FCM Completely Disabled
- **Where:** `.env:24`, `docker-compose.yml:220-224`, `backend/.env.local:7-8`, `backend/src/lib/fcm.ts:51-76`, `backend/src/gateway/chat-gateway.ts:604`.
- **Mechanism:** `docker-compose.yml` reads `FCM_CREDENTIALS_FILE` / `FIREBASE_*` from root `.env`, where `FCM_CREDENTIALS_FILE=` is empty and `FIREBASE_*` are unset. Credentials were placed in `backend/.env.local` pointing to host path `/home/itsupport/cpchat/backend/firebase-service-account.json`, which Docker Compose neither loads nor mounts into the container.
- **Live proof:** `cp-chat-gateway-1` startup log line 1:
  ```json
  {"level":40,"name":"gateway","msg":"FCM disabled: set FCM_CREDENTIALS_FILE or FIREBASE_PROJECT_ID + FIREBASE_CLIENT_EMAIL + FIREBASE_PRIVATE_KEY"}
  ```
  Inside the container, all 5 FCM env vars are empty strings (`FIREBASE_PRIVATE_KEY` length `0`).
- **Why silent per-message:** `maybeNotify()` returns immediately on `if (!this.notifications.enabled) return;` (`backend/src/gateway/chat-gateway.ts:604`) with no log line.
- *(Note: `backend/firebase-service-account.json` and `mobile/android/app/google-services.json:4` both match project `cpchat-a7734`.)*

#### 3. `[CONFIRMED — Stale Local Build Artifacts]` Local APKs on Disk Lack `google-services.json` Resources
- **Where:** `mobile/android/app/build.gradle.kts:16-18`, `mobile/build/app/outputs/apk/{debug,release}/app-*.apk`.
- **Evidence:** Both local APKs are dated `2026-11-24 06:37–06:40 UTC` — before `google-services.json` (`2026-11-25 01:40 UTC`) and commit `8fc83be` (`2026-11-25 02:18 UTC`). `aapt2 dump resources`/`strings` confirms `google_app_id`, `gcm_defaultSenderId`, and `cpchat-a7734` are **absent** from both APKs. Any device running those APKs fails at `Firebase.initializeApp()` (`mobile/lib/core/notifications/fcm_service.dart:63-79`). (Even if APKs were rebuilt elsewhere with `google-services.json`, Root Causes #1 and #2 still break FCM completely.)

#### 4. `[CONFIRMED — Secondary Code Bugs Affecting Reliability & Diagnostics]`
- **`PushRegistration.start()` throws `[core/no-app]` when Firebase is unavailable:** `mobile/lib/core/notifications/push_registration.dart:39-41` reads `FcmService.onTokenRefresh` (`FirebaseMessaging.instance.onRegistered`) unconditionally even when `FcmService.isAvailable == false`, throwing out of unguarded `SessionLifecycle._start()` (`mobile/lib/core/providers.dart:240-247`) before `requestPermission()` runs.
- **No retry after cold-start `currentToken()` failure/timeout:** If `register()` fails or times out (10 s) on an offline launch (`mobile/lib/core/notifications/fcm_service.dart:95`), `PushRegistration` never retries registration when connectivity returns.
- **Mismatched channel ID in `MainActivity.kt`:** `mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt:20-34` creates channel `"messages"`, while `backend/src/lib/fcm.ts:108`, `mobile/android/app/src/main/AndroidManifest.xml:50-52`, and `mobile/lib/core/notifications/local_notification_service.dart:30` all use `"cpchat_messages"`.
- **Test account `Hutri` is `dnd` & skip logs are suppressed by `LOG_LEVEL=info`:** In Postgres, `Hutri` has `status = 'dnd'`, which causes `maybeNotify()` to skip FCM (`backend/src/gateway/chat-gateway.ts:616-620`). Skip reasons are logged at `debug` level (`backend/src/gateway/chat-gateway.ts:609`, `618`, `624`) while `.env:32` runs `LOG_LEVEL=info`.

### Needs Runtime Verification After Fixing #1–#3

#### 5. `[NEEDS RUNTIME VERIFICATION]` Google Play Services Version Gate for FID v1 Registration (`gmsVersionCode >= 261200000`)
- Disassembly of `firebase-messaging-26.0.2.aar` (`GmsRegistrationClient.haveV1RegistrationSupport()`) shows v1 FID registration requires Google Play Services version code `>= 261200000`; on older GMS (e.g., an older stock Android Emulator image or un-updated device), `registerInternal()` falls back to `gmsRpc.getToken(true)`.
- Once `firebase_messaging_installation_id_enabled=true` is added and credentials are enabled on the gateway, verify on the stock emulator and both physical devices that the value emitted by `onRegistered` is accepted by `firebase-admin` 14's `sendEachForMulticast({ fids })` (watch for `FCM rejected a send` with `messaging/invalid-argument` in gateway logs).

#### 6. `[NEEDS RUNTIME VERIFICATION]` Abrupt-Kill Stale Socket Window (0–45 s)
- If a device/network drops without TCP FIN when swiped away, `ChatGateway.hasConnectedDevice()` (`backend/src/gateway/chat-gateway.ts:659-664`) skips FCM until the 20 s heartbeat sweep terminates the dead socket (up to ~40 s, `backend/src/gateway/chat-gateway.ts:41`, `302-318`) or `CONNECTION_TTL_SECONDS` (45 s, `backend/src/config.ts:28`) expires. (Gateway logs show clean `ws disconnected` on swipe-away in recent tests, so this is only a brief race window if TCP FIN is lost.)

---

## 3. Runtime Verification Checklist

Run these read-only checks to independently verify each finding now and after applying fixes:

### 1. Verify DB registered device tokens & recipient DND status
```bash
docker exec cp-chat-postgres-1 psql -U cpchat -d cpchat -c \
  "SELECT u.name, u.status, dt.device_id, left(dt.fcm_token, 24) AS fid_prefix, length(dt.fcm_token) AS len, dt.updated_at
   FROM users u LEFT JOIN device_tokens dt ON dt.user_id = u.id
   ORDER BY dt.updated_at DESC NULLS LAST;"
```
- **Current state:** `device_tokens` has `0` rows; `Hutri` has `status = 'dnd'`.
- **Expected after fix:** Each logged-in Android device has a non-empty row, and test recipient is `online` (not `dnd`).

### 2. Verify gateway FCM initialization & dispatch logs
```bash
# Check FCM init status at gateway boot
docker logs cp-chat-gateway-1 2>&1 | grep -iE "FCM initialized|FCM disabled|FCM initialization failed"

# Watch live gateway logs while sending a message to a swiped-away recipient
docker logs -f --tail 50 cp-chat-gateway-1 2>&1 | grep -iE "ws disconnected|FCM|push|ws send accepted"
```
- **Current state:** Prints `FCM disabled: set FCM_CREDENTIALS_FILE or FIREBASE_PROJECT_ID + FIREBASE_CLIENT_EMAIL + FIREBASE_PRIVATE_KEY`.
- **Expected after fix:** Prints `FCM initialized` on startup, and after sending to a terminated recipient prints `FCM multicast sent` with `"sent":1,"failed":0` (and no `FCM rejected a send`).

### 3. Verify API received token registration calls
```bash
docker logs cp-chat-api-1 2>&1 | grep "/api/v1/devices/fcm-token"
```
- **Current state:** Empty output (0 requests).
- **Expected after fix:** `POST /api/v1/devices/fcm-token` returning `204`.

### 4. Verify live Android device/emulator `adb logcat` (registration + terminated push delivery)
```bash
# A. On app launch / login — verify Firebase init + register() error or success
adb logcat -v time | grep -iE "flutter|FLTFire|FirebaseMessaging|cp_chat|API disabled|FCM"

# B. Verify active Google Play Services version code (check against 261200000)
adb shell dumpsys package com.google.android.gms | grep -m 2 versionCode

# C. Swipe app away from recents, send a message from another account, and watch FCM receipt
adb logcat -v time | grep -iE "FLTFireMsgReceiver|FLTFireMsgService|FLTFireBGExecutor|FirebaseMessaging|NotificationManager|cpchat_messages"
```
- **Current state on A:** Shows either `[core/no-app]` (stale APK without `google-services.json`) or `FCM registration unavailable: ... IllegalStateException: API disabled. Please enable it by adding <meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />`.

### 5. Verify `google-services.json` is actually compiled into the installed APK
```bash
/home/itsupport/toolchains/android-sdk/build-tools/36.0.0/aapt2 dump resources \
  /home/itsupport/cpchat/mobile/build/app/outputs/apk/release/app-release.apk \
  | grep -iE "google_app_id|project_id|gcm_defaultSenderId" -A 1
```
- **Current state:** Empty output.
- **Expected after rebuild:** Shows `project_id = "cpchat-a7734"`, `google_app_id = "1:214754557522:android:8546c37f09945a307a298b"`, and `gcm_defaultSenderId = "214754557522"`.

---

## 4. Proposed Fix Plan (High-Level Only)

1. **Mobile Manifest (`mobile/android/app/src/main/AndroidManifest.xml`):**
   - Add `<meta-data android:name="firebase_messaging_installation_id_enabled" android:value="true" />` inside `<application>` so `FirebaseMessaging.instance.register()` / `onRegistered` is enabled in `firebase-messaging:26.0.2`. *(Alternative if older Play Services devices/emulators cannot use FID v1: switch both mobile `FcmService` and backend `fcm.ts` to standard FCM registration tokens via `getToken()`/`onTokenRefresh` + `tokens: [...]` instead of FID `register()`/`fids: [...]` — test GMS compatibility first per Verification #5.)*
2. **Mobile Native Channel Parity (`mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt`):**
   - Change the eagerly created channel ID in `MainActivity.kt` from `"messages"` to `"cpchat_messages"` so it matches `AndroidManifest.xml`, `LocalNotificationService`, and backend `fcm.ts`.
3. **Mobile Push Registration Hardening (`fcm_service.dart`, `push_registration.dart`, `providers.dart`):**
   - Guard `PushRegistration.start()` on `FcmService.isAvailable` (and catch errors in `SessionLifecycle._start()`) so an unavailable Firebase instance never throws `[core/no-app]` or blocks `requestPermission()`.
   - Log FCM initialization and registration failures through `AppLogger` (not only `debugPrint`) so failures surface in `/logs`.
   - Retry FID/token registration if an initial offline cold-start attempt returns `null` (e.g., on WebSocket reconnect).
   - Call `api.unregisterFcmToken()` during logout teardown if appropriate.
4. **Backend Container FCM Credentials (`.env` / `docker-compose.yml`):**
   - Provide the `cpchat-a7734` service-account credentials to the `gateway` service via inline `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY` in root `.env` (or mount `./backend/firebase-service-account.json` read-only in `docker-compose.yml` and set `FCM_CREDENTIALS_FILE` to the container path), then recreate `cp-chat-gateway-1` and confirm `FCM initialized` in startup logs.
   - *(Optional for diagnostics)* Temporarily set `LOG_LEVEL=debug` on `gateway` (or promote `push skipped: no registered device token` to `info`) while validating.
5. **Rebuild & Re-test:**
   - Rebuild the Android APK with `google-services.json` and the manifest fix included, ensure the test recipient account is not set to `dnd`, verify `device_tokens` populates in Postgres, swipe the app away, and verify `FCM multicast sent` + Android tray notification appearance across Samsung, Poco, and Stock Emulator.

---

## Pipeline Status Summary

| Stage | Component | Status | Finding |
|---|---|---|---|
| 1. Message send & offline detection | `backend/src/gateway/chat-gateway.ts:598-664` | **OK (logic)** | Correctly falls through to `maybeNotify()` when no open WS / live Redis conn; skips `dnd` users (`Hutri` is currently `dnd`). |
| 2. Backend FCM initialization | `backend/src/lib/fcm.ts:51-76`, `.env:24`, `docker-compose.yml:220-224` | **BROKEN (live env)** | `cp-chat-gateway-1` has empty FCM env vars and logs `FCM disabled`. |
| 3. Mobile Firebase init | `mobile/android/app/build.gradle.kts:16-18`, `mobile/android/app/google-services.json` | **OK in source / BROKEN in local APKs** | Source is wired correctly; APKs on disk predate `google-services.json` and lack `google_app_id`. |
| 4. Mobile FCM token/FID registration | `mobile/lib/core/notifications/fcm_service.dart:90-100`, `mobile/android/app/src/main/AndroidManifest.xml` | **BROKEN (code bug)** | `FirebaseMessaging.register()` throws `IllegalStateException: API disabled` because `firebase_messaging_installation_id_enabled=true` meta-data is missing; `device_tokens` table has **0 rows**. |
| 5. FCM payload & terminated display | `backend/src/lib/fcm.ts:90-110`, `mobile/lib/main.dart:32`, `mobile/lib/core/notifications/fcm_service.dart:35-51` | **OK (once 2–4 fixed)** | Sends high-priority `notification` + `data` payload targeting `cpchat_messages`, so Android renders it natively in terminated state; background handler is `@pragma('vm:entry-point')` and avoids duplicates when `message.notification != null`. Channel ID in `MainActivity.kt` (`"messages"`) is mismatched and should align to `"cpchat_messages"`. |
