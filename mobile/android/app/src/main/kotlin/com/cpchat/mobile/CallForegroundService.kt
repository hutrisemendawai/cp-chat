package com.cpchat.mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Ongoing voice/video call foreground service.
 *
 * Uses `FOREGROUND_SERVICE_TYPE_MICROPHONE` for voice calls and dynamically
 * upgrades to `FOREGROUND_SERVICE_TYPE_MICROPHONE | FOREGROUND_SERVICE_TYPE_CAMERA`
 * on Android 14+ ONLY when `CAMERA` permission is currently granted, avoiding
 * Android 14/15/16 SecurityExceptions when upgrading mid-call.
 */
class CallForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "cpchat_ongoing_call"
        const val NOTIFICATION_ID = 9401
        const val ACTION_START_OR_UPDATE = "com.cpchat.mobile.action.CALL_FGS_START_OR_UPDATE"
        const val ACTION_STOP = "com.cpchat.mobile.action.CALL_FGS_STOP"
        const val ACTION_HANGUP = "com.cpchat.mobile.action.CALL_FGS_HANGUP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_WITH_CAMERA = "with_camera"

        @Volatile
        var onHangupAction: (() -> Unit)? = null

        fun startOrUpdate(
            context: Context,
            title: String,
            subtitle: String,
            withCamera: Boolean,
        ) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_START_OR_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_SUBTITLE, subtitle)
                putExtra(EXTRA_WITH_CAMERA, withCamera)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.stopService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_HANGUP -> {
                onHangupAction?.invoke()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Ongoing call"
                val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE) ?: "Tap to return to call"
                val withCamera = intent?.getBooleanExtra(EXTRA_WITH_CAMERA, false) ?: false
                ensureChannel()
                val notification = buildNotification(title, subtitle)
                promoteToForeground(notification, withCamera)
                return START_STICKY
            }
        }
    }

    private fun promoteToForeground(notification: Notification, withCamera: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val hasMic = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
            val hasCam = withCamera && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.CAMERA,
            ) == PackageManager.PERMISSION_GRANTED

            var types = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                if (hasMic) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (hasCam) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if (types != 0) {
                startForeground(NOTIFICATION_ID, notification, types)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(title: String, subtitle: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val hangupIntent = Intent(this, CallForegroundService::class.java).apply {
            action = ACTION_HANGUP
        }
        val hangupPending = PendingIntent.getService(
            this,
            1,
            hangupIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPending)
            .addAction(0, "Hang up", hangupPending)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Ongoing Calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps active voice and video calls connected in the background"
            setSound(null, null)
            enableVibration(false)
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
