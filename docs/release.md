# Android production release

How to produce, sign, and ship the CP Chat Android app to Google Play, and what
the release build changes relative to debug.

## What the release build does

| Change | Where | Why |
| --- | --- | --- |
| R8 minify + resource shrink | `android/app/build.gradle.kts` | Smaller, obfuscated artifact |
| Keep rules | `android/app/proguard-rules.pro` | Flutter engine, plugins, Crashlytics survive R8 |
| Release signing | `android/key.properties` | Play requires a stable upload key |
| App Bundle (`.aab`) | `flutter build appbundle` | Play delivers per-device splits |
| Crashlytics | `lib/core/notifications/crash_reporter.dart` | Crash + non-fatal reporting in release only |
| Cleartext disabled | `res/xml/network_security_config.xml` | TLS everywhere |
| Backups disabled | `AndroidManifest.xml` + `res/xml/data_extraction_rules.xml` | E2EE private keys cannot be extracted |

## 1. Create the upload keystore (once)

```bash
keytool -genkey -v \
  -keystore mobile/android/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

Store the keystore and its passwords in a secret manager. If they are lost you
cannot publish updates under `com.cpchat.mobile`.

## 2. Configure signing

```bash
cp mobile/android/key.properties.example mobile/android/key.properties
# edit storePassword / keyPassword / keyAlias
```

`key.properties`, `*.jks`, and `*.keystore` are git-ignored. Without
`key.properties` the release build falls back to the debug key so local builds
still work — never upload that artifact to a Play track.

## 3. Build the App Bundle

```bash
cd mobile
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=WS_BASE_URL=wss://api.example.com
```

Output: `mobile/build/app/outputs/bundle/release/app-release.aab`.

Build an APK for sideloading/testing instead:

```bash
flutter build apk --release --split-per-abi \
  --dart-define=API_BASE_URL=... --dart-define=WS_BASE_URL=...
```

## 4. Upload the mapping file

R8 writes the deobfuscation map to
`android/app/build/outputs/mapping/release/mapping.txt`. Upload it to Crashlytics
(either via the Gradle plugin with `firebaseCrashlyticsMappingFileUploadEnabled`
or the Firebase console) with every release so crash stack traces are readable.

## 5. Play internal testing track

1. Create the app in the Play Console with package name `com.cpchat.mobile`.
2. Enable **App signing by Google Play**; upload the `.aab` above as the first
   upload key artifact.
3. Create an **Internal testing** release, add testers, and roll out.
4. Promote to Closed/Open testing after the internal smoke run passes.

### Store listing checklist

- Data safety form: declare messages, contacts (if enabled), and device ids;
  state that messages are end-to-end encrypted and not readable by the server.
- Privacy policy URL.
- Content rating questionnaire.
- App icon, feature graphic, and screenshots.
- Target API level meets the current Play requirement (the build inherits
  `flutter.targetSdkVersion`).

## 6. Certificate pinning

`network_security_config.xml` ships with pinning commented out. Once the
production host and certificate chain are known, add a `<pin-set>` with **at
least two** SHA-256 SPKI pins (current + backup CA). Pin the CA or intermediate,
not the leaf, so routine certificate renewal is not an outage. Always set a
`pin-set` `expiration` date.

## Release checklist

- [ ] `make backend-test`, `make mobile-test`, `make mobile-analyze` green
- [ ] Version bumped in `mobile/pubspec.yaml` (both `version` and `+build`)
- [ ] `key.properties` present and points at the upload keystore
- [ ] `google-services.json` present for FCM and Crashlytics
- [ ] `API_BASE_URL` / `WS_BASE_URL` point at TLS endpoints
- [ ] Mapping file archived with the release
- [ ] Internal testing rollout verified on a physical device
