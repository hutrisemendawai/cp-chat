# CP Chat — Flutter Android Client

Flutter Android app for CP Chat. Phase 0 ships the foundation: Riverpod state
management, a Drift/SQLite local store, secure token storage, a REST client, a
reconnecting WebSocket client, and FCM bootstrap.

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
(`http://10.0.2.2:8080` REST, `ws://10.0.2.2:8081` WebSocket). Override for a
physical device or a remote backend:

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

Cleartext HTTP is enabled only in the debug manifest. Release builds require
HTTPS/WSS.

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
│   ├── database/       # Drift tables: conversations, messages, outbox
│   ├── network/        # Dio REST client and reconnecting WebSocket
│   ├── notifications/  # FCM initialization and streams
│   ├── storage/        # Secure JWT storage
│   └── providers.dart  # Riverpod providers for the core services
└── features/
    └── home/           # Placeholder shell until auth lands in Phase 1
```

## Checks

```bash
flutter analyze
flutter test
```
