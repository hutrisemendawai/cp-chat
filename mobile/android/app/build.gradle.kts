import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Crashlytics symbol upload runs after minification so obfuscated stack
    // traces are symbolicated in the Firebase console.
    id("com.google.firebase.crashlytics")
}

// Applied only when a config is present so a fresh clone or CI without the file
// still configures. Without it Firebase.initializeApp() finds no options and
// FCM push stays disabled at runtime.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

/**
 * Release signing is read from `android/key.properties` (git-ignored) so the
 * keystore never lives in the repository. When the file is absent — a fresh
 * clone, CI without secrets — the release build falls back to the debug key so
 * `flutter build appbundle` still works for local verification. A real upload
 * to Play must use the release key.
 */
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.cpchat.mobile"
    // flutter_local_notifications compiles against Android SDK 37, so the app
    // must compile against at least that. compileSdk is backward compatible;
    // take the higher of the Flutter default and the plugin's requirement.
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on Android; desugaring
        // back-ports it to the app's minSdk (24).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.cpchat.mobile"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // R8 shrinks, obfuscates, and optimises the Dart/Java bridge. Flutter
            // ships the keep rules it needs; see proguard-rules.pro for the app's
            // own additions (Flutter engine, plugins, Crashlytics).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Strip debug symbols from the release binary.
            isDebuggable = false
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Debug signing keeps `flutter build appbundle` working locally;
                // never ship this artifact to Play.
                signingConfigs.getByName("debug")
            }
        }
        debug {
            // Crashlytics stays quiet in debug so local runs do not pollute the
            // production dashboard.
            isMinifyEnabled = false
        }
    }

    // The R8 mapping file is emitted to
    // build/app/outputs/mapping/<variant>/mapping.txt. Upload it with each
    // release (`-PfirebaseCrashlyticsMappingFileUploadEnabled=true` or the
    // Play Console) so obfuscated stack traces can be deobfuscated.

    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
