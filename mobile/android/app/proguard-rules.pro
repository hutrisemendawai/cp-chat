# R8 / ProGuard rules for the CP Chat release build.
#
# Flutter's Gradle plugin ships consumer rules that keep the engine and
# generated plugin registrant. These additions cover the app's own surfaces and
# the libraries whose reflection is not described by their consumer rules.

# Crashlytics: keep the classes it reflects over and the generated
# deobfuscation metadata.
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
-keep class com.google.firebase.crashlytics.** { *; }

# Flutter embedding entry points.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.firebase.** { *; }
-keep class com.cpchat.storage_dirs.** { *; }

# Serialization of plugin data classes via JSON.
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Preserve generic signatures used by Kotlin reflection in plugins.
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Do not warn about optional dependencies pulled in by Firebase.
-dontwarn com.google.firebase.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# Flutter's engine ships FlutterPlayStoreSplitApplication, which references the
# Play Core split-install classes. The app does not use deferred components, so
# those classes are absent from the classpath. R8 treats a missing class
# referenced by a kept class as a release-build error; this rule tells it to
# ignore that optional reference.
-dontwarn com.google.android.play.core.**
