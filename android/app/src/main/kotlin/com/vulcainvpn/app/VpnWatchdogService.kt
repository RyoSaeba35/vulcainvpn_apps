package com.vulcainvpn.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

class VpnWatchdogService : Service() {

    companion object {
        private const val TAG = "VpnWatchdogService"
        private const val NOTIFICATION_ID = VpnConstants.SHARED_NOTIFICATION_ID
        private const val CHANNEL_ID = VpnConstants.NOTIFICATION_CHANNEL_ID
        private const val CHECK_INTERVAL_MS = 30000L
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var isRunning = false

    private val healthCheckRunnable = object : Runnable {
        override fun run() {
            if (isRunning) {
                performHealthCheck()
                handler.postDelayed(this, CHECK_INTERVAL_MS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        VpnLogger.log(TAG, "🐕 VpnWatchdogService created (separate process)")
        Log.d(TAG, "🐕 Watchdog service created in process: ${android.os.Process.myPid()}")

        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnLogger.log(TAG, "🐕 VpnWatchdogService started")
        Log.d(TAG, "🐕 Watchdog service started")

        // ✅ MODIFIÉ: Récupère le contenu de la notification depuis l'Intent
        val notificationTitle = intent?.getStringExtra("notification_title") ?: "Vulcain VPN"
        val notificationText = intent?.getStringExtra("notification_text") ?: "Connected"

        // ✅ Démarre en foreground avec la MÊME notification que MyVpnService
        startForeground(NOTIFICATION_ID, createMatchingNotification(notificationTitle, notificationText))

        if (!isRunning) {
            isRunning = true
            handler.post(healthCheckRunnable)
            VpnLogger.log(TAG, "✅ Health checks started (every ${CHECK_INTERVAL_MS/1000}s)")
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                VpnConstants.NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN service status"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }

    private fun createMatchingNotification(title: String, text: String): Notification {
        // ✅ MODIFIÉ: Crée la MÊME notification que MyVpnService
        val stopIntent = Intent(this, MyVpnService::class.java).apply {
            action = "STOP_VPN"
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setSilent(true)
            .setContentIntent(contentIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Disconnect",
                stopPendingIntent
            )
            .setDeleteIntent(stopPendingIntent)
            .setGroup("vpn_services")
            .setGroupSummary(false)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .build()
    }

    private fun performHealthCheck() {
        val shouldBeRunning = getVpnExpectedState()
        val isActuallyRunning = getVpnActualState()

        VpnLogger.log(TAG, "🔍 Health check: Expected=$shouldBeRunning, Actual=$isActuallyRunning")
        Log.d(TAG, "🔍 VPN health: should=$shouldBeRunning, actual=$isActuallyRunning")

        if (!shouldBeRunning) {
            VpnLogger.log(TAG, "⏹️ VPN should not be running - stopping watchdog")
            Log.d(TAG, "⏹️ Stopping watchdog (VPN not expected)")
            stopSelf()
            return
        }

        if (shouldBeRunning && !isActuallyRunning) {
            // ✅ AJOUTE: Double-check après 5 secondes pour éviter les faux positifs
            VpnLogger.log(TAG, "⚠️ VPN appears dead - double-checking in 5s...")
            Log.w(TAG, "⚠️ VPN appears dead - waiting 5s to confirm...")

            handler.postDelayed({
                // Re-vérifier après 5 secondes
                val stillShouldBeRunning = getVpnExpectedState()
                val stillNotRunning = !getVpnActualState()

                if (stillShouldBeRunning && stillNotRunning) {
                    VpnLogger.critical(TAG, "🚨 SILENT VPN DEATH CONFIRMED BY WATCHDOG!")
                    Log.e(TAG, "🚨 WATCHDOG CONFIRMED VPN DEATH!")

                    val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    prefs.edit().apply {
                        putString("death_reason", "service_killed")
                        putString("death_message", "VPN service died silently (detected by watchdog)")
                        putLong("death_timestamp", System.currentTimeMillis())
                        putBoolean("has_unread_death", true)
                        putBoolean(KEY_IS_RUNNING, false)
                        apply()
                    }

                    triggerAutoReconnect()
                    stopSelf()
                } else {
                    VpnLogger.log(TAG, "✅ False alarm - VPN state resolved")
                    Log.d(TAG, "✅ VPN state resolved (was stopping)")
                }
            }, 5000)
        }
    }

    private fun getVpnExpectedState(): Boolean {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_IS_RUNNING, false)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error reading VPN expected state", e)
            false
        }
    }

    private fun getVpnActualState(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking VPN actual state", e)
            false
        }
    }

    private fun triggerAutoReconnect() {
        try {
            VpnLogger.log(TAG, "🚀 Triggering AutoReconnectService")
            Log.d(TAG, "🚀 Starting AutoReconnectService")

            val intent = Intent(this, AutoReconnectService::class.java).apply {
                putExtra("reason", "watchdog_detected_death")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            VpnLogger.log(TAG, "✅ AutoReconnectService triggered")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to trigger AutoReconnect", e)
            Log.e(TAG, "Failed to start AutoReconnectService: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 VpnWatchdogService destroyed")
        Log.d(TAG, "🔴 Watchdog service destroyed")
        isRunning = false
        handler.removeCallbacks(healthCheckRunnable)
    }
}
