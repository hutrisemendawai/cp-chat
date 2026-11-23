# CP Chat — Flutter Android Client

Flutter Android app for CP Chat: 1:1 and group messaging with Riverpod state
management, a Drift/SQLite local store, secure token storage, a reconnecting
WebSocket client, E2EE for direct chats, user profiles, a people directory, and
friends.

## Prerequisites

- Flutter 3.50.x (stable) and the Android SDK
- An Android emulator (API 24+) or a USB device with debugging enabled
- The backend stack running: `make up && make migrate-up` from the repo root

## Run

```bash
flutter pub get
dart run build_runner build   # regenerates lib/core/database/app_database.g.dart
flutter run -d android
```

The app defaults to the backend on the host machine via `10.0.2.2`
(`http://10.0.2.2:8080` REST, `ws://10.0.2.2:8081` WebSocket). Both endpoints are
compile-time overrides:

```bash
flutter run -d android \
  --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=WS_BASE_URL=wss://api.example.com
```

For USB devices without DNS access to the host:

```bash
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8081 tcp:8081
```

## Physical device on a LAN

A physical phone needs the host's LAN IP, not `localhost`. Two rules apply:

1. **Only the API and gateway ports matter.** Media uploads (`POST
   /api/v1/media/upload`) and downloads (`GET /api/v1/media/*`) are proxied
   through the API, so MinIO's port 9000 does not have to be exposed.
2. **LAN builds must be debug builds.** The release network policy
   (`android/app/src/main/res/xml/network_security_config.xml`) blocks cleartext
   HTTP; the debug source set overrides it to permit plain HTTP/WS.

Find the host IP (`hostname -I` or `ip addr`), make sure ports 8080/8081 are
reachable from the phone on the same Wi-Fi, then build an installable APK:

```bash
# from the repo root
make mobile-apk \
  API_BASE_URL=http://192.168.1.20:8080 \
  WS_BASE_URL=ws://192.168.1.20:8081

adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

`make mobile-apk` runs `flutter build apk --debug` with the two `--dart-define`
values. Pass `MODE=release` only when the endpoint is HTTPS/WSS. The equivalent
raw command is:

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=http://192.168.1.20:8080 \
  --dart-define=WS_BASE_URL=ws://192.168.1.20:8081
```

If presigned URLs are needed (instead of streamed downloads), also set
`S3_PUBLIC_ENDPOINT=http://<host-ip>:9000` on the backend so the signature
matches a host the phone can reach.

## Live logs

Every device can forward diagnostics to the shared backend buffer, and the
whole stack's log timeline is visible at `http://<host>:<api-port>/logs` (for
example `http://192.168.1.20:8080/logs`). The dashboard shows `mobile` entries
alongside `rest` and `gateway` ones with a 1-hour retention. See
[../docs/logging.md](../docs/logging.md).

## Firebase (FCM)

Push notifications are inactive until Firebase is configured:

1. Register the package name `com.cpchat.mobile` in the Firebase Console.
2. Download `google-services.json` into `android/app/` (git-ignored).
3. Enable the Google Services plugin in `android/settings.gradle.kts` and
   `android/app/build.gradle.kts`.

Without `google-services.json`, `FcmService.initialize()` logs a warning and the
app runs normally.

## Layout

```
lib/
├── main.dart
├── core/
│   ├── config/         # API/WS endpoints and dart-define overrides
│   ├── crypto/         # E2EE key material, X3DH, and the symmetric ratchet
│   ├── database/       # Drift tables: conversations, messages, outbox
│   ├── logging/        # AppLogger forwarding diagnostics to the backend
│   ├── media/          # Presign/upload/download for images and files
│   ├── models/         # API DTOs and presence/profile parsing
│   ├── network/        # Dio REST client and reconnecting WebSocket
│   ├── notifications/  # FCM initialization and streams
│   ├── storage/        # Secure JWT storage
│   └── widgets/        # Shared presence badges, avatars, status dots
├── features/
│   ├── auth/           # Login, register, session restore
│   ├── chat/           # Message stream, outbox retry, media bubbles
│   ├── conversations/  # Chat list, unread badges
│   ├── groups/         # Create group, group info and member management
│   ├── home/           # Bottom-navigation shell (Chats / People / Profile)
│   ├── people/         # People directory and user profile viewer
│   ├── presence/       # Discord-style status picker
│   ├── profile/        # Own profile editing
│   └── search/         # In-chat and global message search
└── shared/widgets/
```

## Checks

```bash
flutter analyze
flutter test
```
