pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
    // Reads google-services.json into the app at build time so Firebase.initializeApp()
    // (and therefore FCM/Crashlytics) has options. Applied by :app only when the
    // file is present, so CI and unit tests need no Firebase project.
    id("com.google.gms.google-services") version "4.6.0" apply false
    // Symbols the release build before upload; version is resolved by the
    // Firebase BOM the Flutter plugin already applies.
    id("com.google.firebase.crashlytics") version "3.0.6" apply false
}

include(":app")
