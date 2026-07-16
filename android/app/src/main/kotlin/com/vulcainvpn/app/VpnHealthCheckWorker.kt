package com.vulcainvpn.app

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * VPN Health Check Worker — Layer 3 backup (WorkManager, every 15 minutes)
 *
 * This runs when both MyVpnService AND VpnWatchdogService have died.
 * WorkManager survives app death, low memory kills, and system cleanup.
 *
 * Detection logic (same 3 steps as VpnWatchdogService):
 *   1. No underlying network → connectivity loss, not VPN death → do nothing
 *   2. Underlying network exists + no VPN transport + ping fails → VPN is dead → reconnect
 *   3. Underlying network exists + transport present + ping fails → broken tunnel → reconnect
 */
class VpnHealthCheckWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    companion object {
        private const val TAG = "VpnHealthCheckWorker"
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val PING_TIMEOUT_MS = 5000
    }

    override fun doWork(): Result {
        VpnLogger.log(TAG, "🔧 WorkManager health check starting...")
        Log.d(TAG, "🔧 WorkManager health check running")

        try {
            val shouldBeRunning = getVpnExpectedState()

            if (!shouldBeRunning) {
                VpnLogger.log(TAG, "⏹️ VPN should not be running — check complete")
                return Result.success()
            }

            // ── Step 1: Check for underlying network ────────────────────────
            // If there's no WiFi/Cellular/Ethernet, this is just a connectivity
            // loss (subway, bad signal, etc.) — the VPN tunnel is not broken.
            // Do nothing and let MyVpnService handle it when network returns.
            val hasUnderlyingNetwork = hasUnderlyingNetwork()
            if (!hasUnderlyingNetwork) {
                VpnLogger.log(TAG, "📵 No underlying network — connectivity loss, not VPN death. Skipping.")
                return Result.success()
            }

            // ── Step 2 & 3: Underlying network exists — check tunnel ─────────
            // Real internet is available. Now check if the VPN tunnel is working.
            // We check transport first (fast, no network call) then ping (confirms
            // traffic is actually flowing). Both must fail to declare VPN dead.
            val hasTransport = getVpnTransportState()
            val pingOk = pingThroughTunnel()

            VpnLogger.log(TAG, "🔍 WorkManager: underlying=true, transport=$hasTransport, ping=$pingOk")

            if (!pingOk) {
                            // Re-check intended state before declaring death.
                            // The VPN may have been intentionally stopped between our
                            // transport check and the ping — avoid false death events
                            // after manual disconnects.
                            val stillShouldBeRunning = getVpnExpectedState()
                            if (!stillShouldBeRunning) {
                                VpnLogger.log(TAG, "⏹️ VPN stopped intentionally — WorkManager skipping death event")
                                return Result.success()
                            }

                            VpnLogger.critical(TAG, "🚨 VPN DEATH DETECTED BY WORKMANAGER (BACKUP LAYER)!")
                Log.e(TAG, "🚨 WORKMANAGER DETECTED VPN DEATH (Watchdog missed it)!")

                val prefs = applicationContext.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                prefs.edit().apply {
                    putString("death_reason", "service_killed")
                    putString("death_message", "VPN died silently (WorkManager backup, transport=$hasTransport)")
                    putLong("death_timestamp", System.currentTimeMillis())
                    putBoolean("has_unread_death", true)
                    putBoolean(KEY_IS_RUNNING, false)
                    apply()
                }

                triggerAutoReconnect()
                return Result.success()
            }

            VpnLogger.log(TAG, "✅ VPN health check passed (ping OK)")
            return Result.success()

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Health check error", e)
            Log.e(TAG, "WorkManager health check error: ${e.message}")
            return Result.retry()
        }
    }

    /**
     * Check if there is real underlying connectivity (WiFi, Cellular, or Ethernet).
     * If false, any apparent VPN issue is just a connectivity loss — not VPN death.
     */
    private fun hasUnderlyingNetwork(): Boolean {
        return try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            for (network in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
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
     * Check if the VPN tunnel interface is present.
     * Fast — no network call. Used alongside ping for full picture.
     */
    private fun getVpnTransportState(): Boolean {
        return try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking VPN transport", e)
            false
        }
    }

    /**
     * Ping our backend THROUGH the VPN tunnel to verify the tunnel is alive.
     * Uses the same heartbeat endpoint as MyVpnService — proven reliable.
     * The 1.1.1.1/cdn-cgi/trace endpoint was blocked by the Paris VPN server.
     * Any HTTP response (even 4xx/5xx) means DNS + tunnel + routing are working.
     * WorkManager runs on a background thread so this blocking call is safe.
     * Intentionally NOT calling protect() — request must route through the VPN.
     */
    private fun pingThroughTunnel(): Boolean {
        return try {
            val masterKey = MasterKey.Builder(applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = androidx.security.crypto.EncryptedSharedPreferences.create(
                applicationContext,
                "FlutterSecureStorage",
                masterKey,
                androidx.security.crypto.EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                androidx.security.crypto.EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            val deviceId = prefs.getString("${prefix}_device_id", null)
            val apiKey = prefs.getString("${prefix}_api_key", null)

            if (deviceId == null || apiKey == null) {
                VpnLogger.log(TAG, "💔 WorkManager tunnel ping: no credentials")
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
            // Any HTTP response means tunnel is alive (DNS + routing work)
            VpnLogger.log(TAG, "💚 WorkManager tunnel ping OK (HTTP $code)")
            true
        } catch (e: Exception) {
            VpnLogger.log(TAG, "💔 WorkManager tunnel ping exception: ${e.message}")
            false
        }
    }

    private fun getVpnExpectedState(): Boolean {
        return try {
            val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_IS_RUNNING, false)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error reading VPN expected state", e)
            false
        }
    }

    private fun triggerAutoReconnect() {
        try {
            VpnLogger.log(TAG, "🚀 Triggering AutoReconnectService from WorkManager")
            val intent = Intent(applicationContext, AutoReconnectService::class.java).apply {
                putExtra("reason", "workmanager_detected_death")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
            VpnLogger.log(TAG, "✅ AutoReconnectService triggered from WorkManager")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to trigger AutoReconnect from WorkManager", e)
        }
    }
}
