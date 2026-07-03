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
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.net.URL
import javax.net.ssl.HttpsURLConnection

class VpnWatchdogService : Service() {

    companion object {
        private const val TAG = "VpnWatchdogService"
        private const val NOTIFICATION_ID = VpnConstants.SHARED_NOTIFICATION_ID
        private const val CHANNEL_ID = VpnConstants.NOTIFICATION_CHANNEL_ID
        private const val CHECK_INTERVAL_MS = 30000L
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val PING_TIMEOUT_MS = 5000
        // Set by AutoReconnectService while cleanup/restart is in progress.
        // Prevents the watchdog from self-destructing during the brief window where
        // is_running=false but a new VPN is about to start.
        private const val KEY_RECONNECT_IN_PROGRESS = "reconnect_in_progress"
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

        val notificationTitle = intent?.getStringExtra("notification_title") ?: "Vulcain VPN"
        val notificationText = intent?.getStringExtra("notification_text") ?: "Connected"

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
        val stopIntent = Intent(this, MyVpnService::class.java).apply {
            action = "STOP_VPN"
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val contentIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
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
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Disconnect", stopPendingIntent)
            .setDeleteIntent(stopPendingIntent)
            .setGroup("vpn_services")
            .setGroupSummary(false)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .build()
    }

    private fun performHealthCheck() {
        val shouldBeRunning = getVpnExpectedState()

        VpnLogger.log(TAG, "🔍 Health check: shouldBeRunning=$shouldBeRunning")

        if (!shouldBeRunning) {
            // ✅ FIX: Before self-destructing, check if AutoReconnectService is currently
            // in the middle of a cleanup+restart cycle. During reconnect, it sends STOP_VPN
            // which clears is_running — but a new VPN is about to start immediately after.
            // If we kill the watchdog here, the reconnected VPN will be left unmonitored.
            val reconnectInProgress = try {
                getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    .getBoolean(KEY_RECONNECT_IN_PROGRESS, false)
            } catch (e: Exception) { false }

            if (reconnectInProgress) {
                VpnLogger.log(TAG, "⏸️ shouldBeRunning=false but reconnect in progress — staying alive")
                return  // Don't stop — AutoReconnectService will restart the VPN shortly
            }

            VpnLogger.log(TAG, "⏹️ VPN should not be running - stopping watchdog")
            stopSelf()
            return
        }

        val hasTransport = getVpnTransportState()
        val hasUnderlyingNetwork = hasUnderlyingNetwork()

        VpnLogger.log(TAG, "📶 transport=$hasTransport, underlyingNetwork=$hasUnderlyingNetwork")

        // ── Step 1: No underlying network at all ────────────────────────────
        // WiFi dropped, subway tunnel, bad signal, airplane mode etc.
        // The VPN tunnel itself is fine — there's just no internet to go through.
        // Do nothing. MyVpnService's own heartbeat will handle this correctly
        // (it already distinguishes network_lost from vpn_broken).
        if (!hasUnderlyingNetwork) {
            VpnLogger.log(TAG, "📵 No underlying network (WiFi/Cellular/Ethernet) — connectivity loss, not VPN death. Skipping.")
            return
        }

        // ── Step 2: Underlying network exists but VPN transport is gone ──────
        // Real internet is available but the VPN tunnel interface has disappeared.
        // This COULD be a false positive (brief flicker during network handoff),
        // so we wait 5 seconds then confirm with a ping before acting.
        if (!hasTransport) {
            VpnLogger.log(TAG, "⚠️ Underlying network present but VPN transport gone — double-checking in 5s...")
            handler.postDelayed({ confirmAndActIfDead("transport_gone") }, 5000)
            return
        }

        // ── Step 3: Transport present but ping fails ─────────────────────────
        // The tunnel interface exists but traffic isn't flowing through it.
        // This catches a broken tunnel that hasn't been cleaned up yet.
        // Run ping on a background thread — don't block the main handler.
        Thread {
            val pingOk = pingThroughTunnel()
            if (!pingOk) {
                VpnLogger.log(TAG, "⚠️ Transport present but ping failed — double-checking in 5s...")
                handler.postDelayed({ confirmAndActIfDead("ping_failed") }, 5000)
            } else {
                VpnLogger.log(TAG, "✅ Health check passed (transport + ping both OK)")
            }
        }.start()
    }

    /**
     * Called 5 seconds after a suspected failure.
     * Re-runs all checks before triggering reconnect, to avoid acting on transient states.
     */
    private fun confirmAndActIfDead(reason: String) {
        val stillShouldBeRunning = getVpnExpectedState()
        if (!stillShouldBeRunning) {
            VpnLogger.log(TAG, "✅ VPN was stopped normally during confirmation wait — no action needed")
            return
        }

        val stillHasUnderlying = hasUnderlyingNetwork()
        if (!stillHasUnderlying) {
            VpnLogger.log(TAG, "📵 Still no underlying network during confirmation — connectivity loss, not VPN death")
            return
        }

        // Underlying network still exists. Run final ping on background thread.
        Thread {
            val pingOk = stillHasUnderlying && pingThroughTunnel()
            if (!pingOk) {
                VpnLogger.critical(TAG, "🚨 VPN DEATH CONFIRMED BY WATCHDOG (reason: $reason)")
                Log.e(TAG, "🚨 WATCHDOG CONFIRMED VPN DEATH!")

                val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                prefs.edit().apply {
                    putString("death_reason", "service_killed")
                    putString("death_message", "VPN died silently (watchdog confirmed, reason: $reason)")
                    putLong("death_timestamp", System.currentTimeMillis())
                    putBoolean("has_unread_death", true)
                    putBoolean(KEY_IS_RUNNING, false)
                    apply()
                }

                handler.post { triggerAutoReconnect() }
                // ✅ Do NOT stopSelf() — keep watching in case reconnect fails.
                // Watchdog stops itself only when getVpnExpectedState() returns false,
                // which happens after a successful disconnect or reconnect.
            } else {
                VpnLogger.log(TAG, "✅ False alarm — VPN recovered during confirmation (transient state)")
            }
        }.start()
    }

    /**
     * Check if the VPN tunnel interface is present (TRANSPORT_VPN on active network).
     * Fast — no network call. Can return false during brief handoffs.
     */
    private fun getVpnTransportState(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking VPN transport state", e)
            false
        }
    }

    /**
     * Check if there is real underlying connectivity (WiFi, Cellular, or Ethernet).
     * If this returns false, any VPN issue is a connectivity loss — not a VPN death.
     * Mirrors MyVpnService.hasUnderlyingNetwork() exactly.
     */
    private fun hasUnderlyingNetwork(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = cm.allNetworks
            for (network in networks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                // Skip the VPN interface itself — we want physical connectivity
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
                    return true
                }
            }
            false
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking underlying network", e)
            false
        }
    }

    /**
     * Ping our backend THROUGH the VPN tunnel to verify the tunnel is alive.
     * The 1.1.1.1/cdn-cgi/trace endpoint was blocked by the Paris VPN server,
     * causing false "VPN dead" detections. Any HTTP response (even 4xx/5xx)
     * proves DNS + tunnel + routing are all working.
     * Must be called from a background thread.
     */
    private fun pingThroughTunnel(): Boolean {
        return try {
            val masterKey = MasterKey.Builder(applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val encPrefs = androidx.security.crypto.EncryptedSharedPreferences.create(
                applicationContext,
                "FlutterSecureStorage",
                masterKey,
                androidx.security.crypto.EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                androidx.security.crypto.EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            val deviceId = encPrefs.getString("${prefix}_device_id", null)
            val apiKey = encPrefs.getString("${prefix}_api_key", null)

            if (deviceId == null || apiKey == null) {
                VpnLogger.log(TAG, "💔 Tunnel ping: no credentials")
                return false
            }

            val url = URL("https://api.vulcainvpn.com/api/heartbeat/$deviceId")
            val connection = url.openConnection() as HttpsURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("X-Api-Key", apiKey)
            connection.setRequestProperty("Content-Type", "application/json")
            connection.connectTimeout = PING_TIMEOUT_MS
            connection.readTimeout = PING_TIMEOUT_MS
            val code = connection.responseCode
            connection.disconnect()
            VpnLogger.log(TAG, "💚 Tunnel ping OK (HTTP $code)")
            true
        } catch (e: Exception) {
            VpnLogger.log(TAG, "💔 Tunnel ping exception: ${e.message}")
            false
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

    private fun triggerAutoReconnect() {
        try {
            VpnLogger.log(TAG, "🚀 Triggering AutoReconnectService")
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
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 VpnWatchdogService destroyed")
        isRunning = false
        handler.removeCallbacks(healthCheckRunnable)
    }
}
