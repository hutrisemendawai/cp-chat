package com.cpchat.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createMessageChannel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNoBackupFilesDir" -> result.success(noBackupFilesDir.absolutePath)
                    "getCacheDir" -> result.success(cacheDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * The gateway addresses pushes with `channelId = "cpchat_messages"`. FCM does
     * not create channels itself, and a missing channel downgrades the
     * notification to default importance, so create it eagerly at startup.
     */
    private fun createMessageChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            "cpchat_messages",
            "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Incoming chat messages"
            enableLights(true)
            enableVibration(true)
        }

        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    companion object {
        private const val STORAGE_CHANNEL = "cpchat/storage"
    }
}
