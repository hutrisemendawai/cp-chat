package com.cpchat.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CALL_SERVICE_CHANNEL = "com.cpchat.mobile/call_service"
    }

    private var callChannel: MethodChannel? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_SERVICE_CHANNEL)
        callChannel = channel

        CallForegroundService.onHangupAction = {
            runOnUiThread {
                callChannel?.invokeMethod("onHangupPressed", null)
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "Ongoing call"
                    val subtitle = call.argument<String>("subtitle") ?: "Tap to return to call"
                    val withCamera = call.argument<Boolean>("withCamera") ?: false
                    try {
                        CallForegroundService.startOrUpdate(this, title, subtitle, withCamera)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("fgs_start_failed", e.message, null)
                    }
                }
                "update" -> {
                    val title = call.argument<String>("title") ?: "Ongoing call"
                    val subtitle = call.argument<String>("subtitle") ?: "Tap to return to call"
                    val withCamera = call.argument<Boolean>("withCamera") ?: false
                    try {
                        CallForegroundService.startOrUpdate(this, title, subtitle, withCamera)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("fgs_update_failed", e.message, null)
                    }
                }
                "stop" -> {
                    CallForegroundService.stop(this)
                    result.success(null)
                }
                "setLockScreenVisible" -> {
                    val visible = call.argument<Boolean>("visible") ?: false
                    setLockScreenVisible(visible)
                    result.success(null)
                }
                "setProximityWakeLock" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setProximityWakeLock(enabled)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        CallForegroundService.onHangupAction = null
        setProximityWakeLock(false)
        super.onDestroy()
    }

    private fun setLockScreenVisible(visible: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(visible)
            setTurnScreenOn(visible)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (visible) {
                window.addFlags(flags)
            } else {
                window.clearFlags(flags)
            }
        }
    }

    private fun setProximityWakeLock(enabled: Boolean) {
        try {
            if (enabled) {
                if (proximityWakeLock == null) {
                    val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
                    if (pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                        proximityWakeLock = pm.newWakeLock(
                            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                            "cpchat:call_proximity",
                        ).apply { setReferenceCounted(false) }
                    }
                }
                if (proximityWakeLock?.isHeld == false) {
                    proximityWakeLock?.acquire(4 * 60 * 60 * 1000L)
                }
            } else {
                if (proximityWakeLock?.isHeld == true) {
                    proximityWakeLock?.release()
                }
            }
        } catch (_: Exception) {
            // Best-effort; some emulators/devices do not support proximity wake locks.
        }
    }

    /**
     * Eagerly creates notification channels at startup so FCM and local call
     * alerts render with the intended importance, sound, and lock-screen policy.
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return

        val messagesChannel = NotificationChannel(
            "cpchat_messages",
            "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Incoming chat messages"
            enableLights(true)
            enableVibration(true)
        }

        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val ringtoneAttrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val callsChannel = NotificationChannel(
            "cpchat_calls",
            "Incoming Calls",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Incoming voice and video calls"
            enableLights(true)
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 600, 400, 600)
            setSound(ringtoneUri, ringtoneAttrs)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val ongoingCallChannel = NotificationChannel(
            CallForegroundService.CHANNEL_ID,
            "Ongoing Calls",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps active voice and video calls connected in the background"
            setSound(null, null)
            enableVibration(false)
        }

        manager.createNotificationChannel(messagesChannel)
        manager.createNotificationChannel(callsChannel)
        manager.createNotificationChannel(ongoingCallChannel)
    }
}
