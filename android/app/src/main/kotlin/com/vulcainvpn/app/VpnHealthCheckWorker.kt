package com.vulcainvpn.app

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * ✅ VPN Health Check Worker - Layer 2 Protection (15-minute backup)
 *
 * WorkManager-based backup check that runs every 15 minutes
 * Survives app death, low memory kills, and system cleanup
 *
 * Catches edge cases where both MyVpnService AND VpnWatchdogService died
 */
class VpnHealthCheckWorker(
    context: Context,
    params: WorkerParameters
) : Worker(context, params) {

    companion object {
        private const val TAG = "VpnHealthCheckWorker"
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
    }

    override fun doWork(): Result {
        VpnLogger.log(TAG, "🔧 WorkManager health check starting...")
        Log.d(TAG, "🔧 WorkManager health check running")

        try {
            val shouldBeRunning = getVpnExpectedState()
            val isActuallyRunning = getVpnActualState()

            VpnLogger.log(TAG, "🔍 WorkManager check: Expected=$shouldBeRunning, Actual=$isActuallyRunning")
            Log.d(TAG, "🔍 VPN state: should=$shouldBeRunning, actual=$isActuallyRunning")

            if (!shouldBeRunning) {
                // VPN should not be running - nothing to do
                VpnLogger.log(TAG, "⏹️ VPN should not be running - check complete")
                return Result.success()
            }

            if (shouldBeRunning && !isActuallyRunning) {
                // 🚨 SILENT VPN DEATH DETECTED BY WORKMANAGER!
                VpnLogger.critical(TAG, "🚨 SILENT VPN DEATH DETECTED BY WORKMANAGER (BACKUP LAYER)!")
                Log.e(TAG, "🚨 WORKMANAGER DETECTED VPN DEATH (Watchdog missed it)!")

                // Mark death event
                val prefs = applicationContext.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                prefs.edit().apply {
                    putString("death_reason", "service_killed")
                    putString("death_message", "VPN service died silently (detected by WorkManager backup)")
                    putLong("death_timestamp", System.currentTimeMillis())
                    putBoolean("has_unread_death", true)
                    putBoolean(KEY_IS_RUNNING, false)
                    apply()
                }

                // Trigger auto-reconnect
                triggerAutoReconnect()

                return Result.success()
            }

            // All good
            VpnLogger.log(TAG, "✅ VPN health check passed")
            return Result.success()

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Health check error", e)
            Log.e(TAG, "WorkManager health check error: ${e.message}")
            return Result.retry()
        }
    }

    /**
     * Check if VPN SHOULD be running (from persistent state)
     */
    private fun getVpnExpectedState(): Boolean {
        return try {
            val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getBoolean(KEY_IS_RUNNING, false)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error reading VPN expected state", e)
            false
        }
    }

    /**
     * Check if VPN IS ACTUALLY running (from network capabilities)
     */
    private fun getVpnActualState(): Boolean {
        return try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
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
            VpnLogger.log(TAG, "🚀 Triggering AutoReconnectService from WorkManager")
            Log.d(TAG, "🚀 Starting AutoReconnectService from WorkManager")

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
            Log.e(TAG, "Failed to start AutoReconnectService from WorkManager: ${e.message}")
        }
    }
}

