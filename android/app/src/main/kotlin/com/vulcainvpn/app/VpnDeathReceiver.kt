package com.vulcainvpn.app

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * 🔧 FIXED: Debounce + Subscription check + Service running check + network_lost reconnectable
 */
class VpnDeathReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "VpnDeathReceiver"

        // 🔧 Debounce to prevent duplicate service starts
        private var lastReconnectAttempt = 0L
        private const val RECONNECT_DEBOUNCE_MS = 2000L  // 2 seconds
    }

    override fun onReceive(context: Context, intent: Intent) {
        VpnLogger.markCrashScenario("VPN_DEATH_BROADCAST_RECEIVED")
        VpnLogger.log(TAG, "📻 VPN_DIED broadcast received")

        if (intent.action != "com.vulcain.vpn.VPN_DIED") {
            VpnLogger.log(TAG, "Ignoring - wrong action: ${intent.action}")
            return
        }

        val reason = intent.getStringExtra("reason") ?: "unknown"
        val message = intent.getStringExtra("message") ?: "VPN died"
        val timestamp = intent.getLongExtra("timestamp", 0)

        VpnLogger.log(TAG, "Death reason: $reason")
        VpnLogger.log(TAG, "Death message: $message")

        // ✅ NEW: Check if death reason is already subscription_expired
        val prefs = context.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
        val storedReason = prefs.getString("death_reason", "")

        if (storedReason == "subscription_expired") {
            VpnLogger.log(TAG, "⛔ Death reason is already subscription_expired - NOT starting auto-reconnect")
            VpnLogger.log(TAG, "This prevents infinite loop when subscription is expired")
            return
        }

        // Store event for Flutter
        try {
            prefs.edit().apply {
                putString("death_reason", reason)
                putString("death_message", message)
                putLong("death_timestamp", timestamp)
                putBoolean("has_unread_death", true)
                apply()
            }
            VpnLogger.log(TAG, "✅ Death event stored in SharedPreferences")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to store event", e)
        }

        // Notify Flutter - safe call ensures no crash if statusSink is null
        try {
            val sink = MainActivity.statusSink
            if (sink != null) {
                VpnLogger.log(TAG, "Notifying Flutter via statusSink")
                sink.success(mapOf(
                    "event" to "vpn_died",
                    "reason" to reason,
                    "message" to message,
                    "timestamp" to timestamp
                ))
                VpnLogger.log(TAG, "✅ Flutter notified successfully")
            } else {
                VpnLogger.log(TAG, "⚠️ statusSink is null, Flutter not notified")
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error notifying Flutter", e)
        }

        // Check if auto-reconnect is enabled
        val settingsPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val autoReconnectEnabled = settingsPrefs.getBoolean("flutter.auto_reconnect_enabled", true)

        // Check if this reason is reconnectable
        val isReconnectable = when (reason) {
            "service_killed" -> true
            "process_crashed" -> true
            "vpn_broken" -> true
            "network_lost" -> true  // ✅ FIXED: network_lost should trigger auto-reconnect!
            "credentials_expired" -> true
            "permission_revoked" -> false
            "subscription_expired" -> false
            "device_revoked" -> false
            else -> false
        }

        VpnLogger.log(TAG, "Auto-reconnect enabled: $autoReconnectEnabled")
        VpnLogger.log(TAG, "Is reconnectable: $isReconnectable")

        val shouldAttemptReconnect = autoReconnectEnabled && isReconnectable

        if (shouldAttemptReconnect) {
            // 🔧 Debounce check
            val now = System.currentTimeMillis()
            if (now - lastReconnectAttempt < RECONNECT_DEBOUNCE_MS) {
                VpnLogger.log(TAG, "⏭️ Skipping reconnect - too soon since last attempt (${now - lastReconnectAttempt}ms ago)")
                return
            }

            // ✅ NEW: Check if AutoReconnectService is already running
            if (isAutoReconnectServiceRunning(context)) {
                VpnLogger.log(TAG, "⚠️ AutoReconnectService is already running - skipping start")
                return
            }

            lastReconnectAttempt = now

            VpnLogger.log(TAG, "🚀 Starting AutoReconnectService")

            try {
                val reconnectIntent = Intent(context, AutoReconnectService::class.java).apply {
                    putExtra("reason", reason)
                    putExtra("message", message)
                    putExtra("timestamp", timestamp)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(reconnectIntent)
                } else {
                    context.startService(reconnectIntent)
                }

                VpnLogger.log(TAG, "✅ AutoReconnectService started successfully")
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Failed to start AutoReconnectService", e)
                try {
                    VpnLogger.log(TAG, "Falling back to notification")
                    showNotification(context, reason)
                } catch (e2: Exception) {
                    VpnLogger.error(TAG, "Failed to show fallback notification", e2)
                }
            }

        } else {
            VpnLogger.log(TAG, "📬 Showing notification (auto-reconnect disabled or not applicable)")
            try {
                showNotification(context, reason)
                VpnLogger.log(TAG, "✅ Notification shown")
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Failed to show notification", e)
            }
        }
    }

    /**
     * ✅ NEW: Check if AutoReconnectService is already running
     * Prevents multiple service instances from running simultaneously
     */
    private fun isAutoReconnectServiceRunning(context: Context): Boolean {
        return try {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            @Suppress("DEPRECATION")
            for (service in manager.getRunningServices(Int.MAX_VALUE)) {
                if (AutoReconnectService::class.java.name == service.service.className) {
                    VpnLogger.log(TAG, "Found running AutoReconnectService")
                    return true
                }
            }
            false
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking if service is running", e)
            false
        }
    }

    private fun showNotification(context: Context, reason: String) {
        VpnLogger.log(TAG, "Creating notification for reason: $reason")

        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = android.app.NotificationChannel(
                    "vpn_status",
                    "VPN Status",
                    android.app.NotificationManager.IMPORTANCE_HIGH
                )
                notificationManager.createNotificationChannel(channel)
                VpnLogger.log(TAG, "Notification channel created")
            }

            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = android.app.PendingIntent.getActivity(
                context,
                0,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )

            val title = when (reason) {
                "subscription_expired" -> "Subscription Expired"
                "service_killed" -> "VPN Stopped"
                "vpn_broken" -> "VPN Disconnected"
                "network_lost" -> "VPN Disconnected"  // ✅ FIXED: Better title for network_lost
                else -> "VPN Disconnected"
            }

            VpnLogger.log(TAG, "Building notification with title: $title")

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.app.Notification.Builder(context, "vpn_status")
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(context)
            }
                .setContentTitle(title)
                .setContentText("Tap to reconnect")
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .build()

            notificationManager.notify(1001, notification)
            VpnLogger.log(TAG, "✅ Notification 1001 posted successfully")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to show notification", e)
        }
    }
}
