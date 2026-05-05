package com.vulcainvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
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
import kotlinx.coroutines.*
import android.provider.Settings
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * ✅ Two-batch retry strategy with cooldown
 *
 * Behavior:
 * - Batch 1: 3 retries (1 min each = 3 min total)
 * - 2-minute cooldown
 * - Batch 2: 3 retries (1 min each = 3 min total)
 * - Total: ~8 minutes before giving up permanently
 * - Reset counter only after 24h or manual reconnection
 */
class AutoReconnectService : Service() {

    companion object {
        private const val TAG = "AutoReconnectService"
        private const val NOTIFICATION_ID = 2000
        private const val CHANNEL_ID = "auto_reconnect"
        private const val DISCONNECT_CHANNEL_ID = "vpn_disconnect"

        // ✅ Two-batch retry strategy
        private const val PREFS_RETRY_NAME = "auto_reconnect_retry"
        private const val KEY_RETRY_COUNT = "retry_count"
        private const val KEY_RETRY_BATCH = "retry_batch"
        private const val KEY_LAST_RETRY_TIME = "last_retry_time"

        private const val MAX_RETRIES_PER_BATCH = 5
        private const val MAX_BATCHES = 1
        private const val BATCH_COOLDOWN_MS = 0L
        private const val RETRY_RESET_TIME_MS = 8 * 60 * 1000L
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var reconnectJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        VpnLogger.log(TAG, "📦 AutoReconnectService onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnLogger.log(TAG, "🔄 AutoReconnectService.onStartCommand")
        Log.d(TAG, "🔄 Auto-reconnect service started")

        try {
            val notification = createNotification("Reconnecting VPN", "Checking network...")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            VpnLogger.log(TAG, "✅ Started foreground with notification ID $NOTIFICATION_ID")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to start foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }

        val reason = intent?.getStringExtra("reason") ?: "unknown"
        VpnLogger.log(TAG, "Death reason: $reason")

        // Check for non-reconnectable reasons
        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
        val storedReason = prefs.getString("death_reason", "")
        if (storedReason == "subscription_expired" || storedReason == "auth_required" ||
            storedReason == "device_revoked" || storedReason == "airplane_mode") {
            VpnLogger.log(TAG, "⛔ Non-reconnectable reason: $storedReason - stopping immediately")

            val (title, message) = when (storedReason) {
                "airplane_mode" -> Pair("VPN Disconnected", "Airplane mode enabled")
                "subscription_expired" -> Pair("VPN Disconnected", "Subscription expired - Please reopen app")
                "auth_required" -> Pair("VPN Disconnected", "Authentication required - Please login again")
                "device_revoked" -> Pair("VPN Disconnected", "Device access revoked - Please login again")
                else -> Pair("VPN Disconnected", "VPN stopped")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }

            stopWatchdogService()

            serviceScope.launch {
                cleanupVpn()
                showDisconnectNotification(title, message)
                stopSelf()
            }
            return START_NOT_STICKY
        }

        // ⭐ Two-batch retry logic
        val retryPrefs = getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
        val lastRetryTime = retryPrefs.getLong(KEY_LAST_RETRY_TIME, 0)
        val now = System.currentTimeMillis()

        // Reset everything if 24 hours passed since last attempt
        if (now - lastRetryTime > RETRY_RESET_TIME_MS) {
            VpnLogger.log(TAG, "🔄 Resetting retry state (24 hours passed)")
            retryPrefs.edit()
                .putInt(KEY_RETRY_COUNT, 0)
                .putInt(KEY_RETRY_BATCH, 1)
                .putLong(KEY_LAST_RETRY_TIME, now)
                .apply()
        }

        val currentRetryCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
        val currentRetryBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)

        // Check if we've exhausted all retries
        if (currentRetryBatch > MAX_BATCHES) {
            VpnLogger.log(TAG, "⛔ All retry batches exhausted - giving up permanently")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }

            showDisconnectNotification(
                "VPN Disconnected",
                "Unable to reconnect - Please reconnect manually"
            )

            stopWatchdogService()

            // Reset for next time user manually reconnects
            retryPrefs.edit()
                .putInt(KEY_RETRY_COUNT, 0)
                .putInt(KEY_RETRY_BATCH, 1)
                .putLong(KEY_LAST_RETRY_TIME, 0)
                .apply()

            serviceScope.launch {
                cleanupVpn()
                showDisconnectNotification(
                    "VPN Disconnected",
                    "Unable to reconnect - Please reconnect manually"
                )
                stopSelf()
            }
            return START_NOT_STICKY
        }

        // Check if we need to wait between batches
        if (currentRetryCount >= MAX_RETRIES_PER_BATCH && currentRetryBatch == 1) {
            val timeSinceLastRetry = now - lastRetryTime

            if (timeSinceLastRetry < BATCH_COOLDOWN_MS) {
                // Still in cooldown period
                val remainingCooldown = BATCH_COOLDOWN_MS - timeSinceLastRetry
                val remainingSeconds = (remainingCooldown / 1000).toInt()
                VpnLogger.log(TAG, "⏸️ Batch 1 complete - waiting ${remainingSeconds}s before batch 2")

                // Update notification to show countdown
                updateNotification(
                    "VPN Reconnecting",
                    "Retrying in ${remainingSeconds}s..."
                )

                // Schedule retry after cooldown
                mainHandler.postDelayed({
                    VpnLogger.log(TAG, "⏰ Cooldown complete - starting batch 2")
                    retryPrefs.edit()
                        .putInt(KEY_RETRY_BATCH, 2)
                        .putInt(KEY_RETRY_COUNT, 0)
                        .putLong(KEY_LAST_RETRY_TIME, System.currentTimeMillis())
                        .apply()

                    // Restart service for batch 2
                    val retryIntent = Intent(this, AutoReconnectService::class.java).apply {
                        putExtra("reason", reason)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(retryIntent)
                    } else {
                        startService(retryIntent)
                    }
                }, remainingCooldown)

                return START_NOT_STICKY
            } else {
                // Cooldown finished, move to batch 2
                VpnLogger.log(TAG, "✅ Cooldown complete - moving to batch 2")
                retryPrefs.edit()
                    .putInt(KEY_RETRY_BATCH, 2)
                    .putInt(KEY_RETRY_COUNT, 0)
                    .putLong(KEY_LAST_RETRY_TIME, now)
                    .apply()
            }
        }

        // Check if we've used all retries in current batch
        val updatedRetryCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
        val updatedBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)

        if (updatedRetryCount >= MAX_RETRIES_PER_BATCH) {
            VpnLogger.log(TAG, "⛔ Batch $updatedBatch exhausted ($updatedRetryCount/$MAX_RETRIES_PER_BATCH)")

            if (updatedBatch >= MAX_BATCHES) {
                // All batches done - give up
                VpnLogger.log(TAG, "⛔ All batches complete - giving up")

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }

                showDisconnectNotification(
                    "VPN Disconnected",
                    "Unable to reconnect - Please reconnect manually"
                )

                retryPrefs.edit()
                    .putInt(KEY_RETRY_COUNT, 0)
                    .putInt(KEY_RETRY_BATCH, 1)
                    .putLong(KEY_LAST_RETRY_TIME, 0)
                    .apply()

                stopSelf()
                return START_NOT_STICKY
            } else {
                // Move to cooldown before next batch
                retryPrefs.edit()
                    .putLong(KEY_LAST_RETRY_TIME, now)
                    .apply()

                // Will trigger cooldown check
                stopSelf()

                // Schedule next check
                mainHandler.postDelayed({
                    val retryIntent = Intent(this, AutoReconnectService::class.java).apply {
                        putExtra("reason", reason)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(retryIntent)
                    } else {
                        startService(retryIntent)
                    }
                }, 1000)

                return START_NOT_STICKY
            }
        }

        // Increment retry count
        retryPrefs.edit()
            .putInt(KEY_RETRY_COUNT, updatedRetryCount + 1)
            .putLong(KEY_LAST_RETRY_TIME, now)
            .apply()

        val currentBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)
        val currentCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
        VpnLogger.log(TAG, "📊 Batch $currentBatch, Attempt $currentCount/$MAX_RETRIES_PER_BATCH")

        reconnectJob?.cancel()
        reconnectJob = serviceScope.launch(Dispatchers.IO) {
            try {
                performReconnection(reason, currentBatch, currentCount)
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Exception in performReconnection", e)
                withContext(Dispatchers.Main) {
                    fail("Error: ${e.message}")
                }
            }
        }

        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun updateNotification(title: String, message: String) {
        try {
            val notification = createNotification(title, message)
            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to update notification", e)
        }
    }

    private suspend fun performReconnection(reason: String, batch: Int, attempt: Int) {
        VpnLogger.log(TAG, "🚀 Starting reconnection (reason: $reason, batch: $batch, attempt: $attempt/$MAX_RETRIES_PER_BATCH)")

        try {
            // Check airplane mode
            if (isAirplaneModeOn()) {
                VpnLogger.log(TAG, "✈️ Airplane mode detected - stopping VPN")

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }

                stopWatchdogService()

                cleanupVpn()

                showDisconnectNotification("VPN Disconnected", "Airplane mode enabled")
                resetRetryState()
                stopSelf()
                return
            }

            // Clean up
            VpnLogger.log(TAG, "🧹 Cleaning up VPN")
            cleanupVpn()

            // ⭐ Try reconnecting for 1 minute (changed from 5)
            VpnLogger.log(TAG, "🔄 Attempting reconnection (1 min timeout)")

            val startTime = System.currentTimeMillis()
            val maxRetryTime = 1 * 60 * 1000L  // ⭐ 1 minute instead of 5
            var subAttempt = 0

            while (System.currentTimeMillis() - startTime < maxRetryTime) {
                subAttempt++

                // Check airplane mode again
                if (isAirplaneModeOn()) {
                    VpnLogger.log(TAG, "✈️ Airplane mode enabled during reconnect")

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(true)
                    }

                    showDisconnectNotification("VPN Disconnected", "Airplane mode enabled")
                    resetRetryState()
                    stopSelf()
                    return
                }

                // Check subscription every 30 seconds
                if (subAttempt % 3 == 0) {
                    VpnLogger.log(TAG, "🔐 Checking subscription status...")
                    val subscriptionStatus = checkSubscription()

                    when (subscriptionStatus) {
                        "expired", "canceled" -> {
                            VpnLogger.log(TAG, "⛔ Subscription expired during reconnect - stopping")

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                            } else {
                                @Suppress("DEPRECATION")
                                stopForeground(true)
                            }

                            stopWatchdogService()

                            cleanupVpn()

                            showDisconnectNotification("VPN Disconnected", "Subscription expired")
                            resetRetryState()
                            stopSelf()
                            return
                        }
                        "auth_failed" -> {
                            VpnLogger.log(TAG, "⛔ Auth failed during reconnect - stopping")

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                            } else {
                                @Suppress("DEPRECATION")
                                stopForeground(true)
                            }

                            stopWatchdogService()

                            cleanupVpn()

                            showDisconnectNotification("VPN Disconnected", "Authentication failed - Please login again")
                            resetRetryState()
                            stopSelf()
                            return
                        }
                        "active" -> {
                            VpnLogger.log(TAG, "✅ Subscription still active")
                        }
                    }
                }

                // Check network
                if (isNetworkAvailable()) {
                    VpnLogger.log(TAG, "✅ Network available - attempting connection (sub-attempt $subAttempt)")

                    val config = getConfig()
                    if (config == null) {
                        VpnLogger.log(TAG, "❌ No config available")
                        fail("No configuration")
                        return
                    }

                    // Try to connect
                    startVpn(config)
                    delay(10000)  // Wait 10s

                    if (isVpnRunning()) {
                        VpnLogger.log(TAG, "✅ Reconnected successfully! (batch $batch, attempt $attempt)")
                        success()
                        return
                    }

                    // Check if failure was due to authentication
                    val vpnStatePrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    val deathReason = vpnStatePrefs.getString("death_reason", "")

                    if (deathReason == "auth_required" || deathReason == "device_revoked" || deathReason == "credentials_expired") {
                        VpnLogger.log(TAG, "⛔ Authentication failed - credentials expired/invalid")

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            stopForeground(STOP_FOREGROUND_REMOVE)
                        } else {
                            @Suppress("DEPRECATION")
                            stopForeground(true)
                        }

                        stopWatchdogService()

                        cleanupVpn()

                        showDisconnectNotification("VPN Disconnected", "Please reconnect manually to refresh credentials")
                        resetRetryState()
                        stopSelf()
                        return
                    }
                }

                // Wait 10s before retry
                VpnLogger.log(TAG, "⏳ Retrying in 10s... (sub-attempt $subAttempt)")
                delay(10000)
            }

            // 1 minute passed for this attempt
            VpnLogger.log(TAG, "⏱️ 1 minute passed for batch $batch, attempt $attempt")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }

            // Check if we should continue
            val retryPrefs = getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
            val currentCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
            val currentBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)

            if (currentCount >= MAX_RETRIES_PER_BATCH && currentBatch >= MAX_BATCHES) {
                // All attempts exhausted - give up permanently
                VpnLogger.log(TAG, "⛔ All batches exhausted - stopping permanently")

                stopWatchdogService()

                cleanupVpn()

                showDisconnectNotification(
                    "VPN Disconnected",
                    "Unable to reconnect - Please reconnect manually"
                )
                resetRetryState()
                stopSelf()
            } else if (currentCount >= MAX_RETRIES_PER_BATCH && currentBatch == 1) {
                // Batch 1 complete, schedule cooldown period
                VpnLogger.log(TAG, "⏸️ Batch 1 complete - scheduling 2-minute cooldown")
                showDisconnectNotification(
                    "VPN Reconnecting",
                    "Retrying in 2 minutes..."
                )

                // Schedule restart after cooldown
                withContext(Dispatchers.Main) {
                    mainHandler.postDelayed({
                        VpnLogger.log(TAG, "⏰ Cooldown complete - starting batch 2")
                        val retryIntent = Intent(this@AutoReconnectService, AutoReconnectService::class.java).apply {
                            putExtra("reason", reason)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(retryIntent)
                        } else {
                            startService(retryIntent)
                        }
                    }, BATCH_COOLDOWN_MS)
                }
                stopSelf()
            } else {
                // More attempts remaining in current batch - schedule next retry
                VpnLogger.log(TAG, "🔄 Scheduling next retry (batch $currentBatch, attempt ${currentCount + 1}/$MAX_RETRIES_PER_BATCH)")
                showDisconnectNotification(
                    "VPN Reconnecting",
                    "Next retry in 10s... (batch $currentBatch, $currentCount/$MAX_RETRIES_PER_BATCH)"
                )

                // Schedule next retry attempt (immediate, just enough delay to avoid tight loop)
                withContext(Dispatchers.Main) {
                    mainHandler.postDelayed({
                        VpnLogger.log(TAG, "🚀 Starting next retry attempt")
                        val retryIntent = Intent(this@AutoReconnectService, AutoReconnectService::class.java).apply {
                            putExtra("reason", reason)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(retryIntent)
                        } else {
                            startService(retryIntent)
                        }
                    }, 10000)  // 10 second delay before next retry
                }
                stopSelf()
            }

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Reconnection failed", e)
            fail("Reconnection error: ${e.message}")
        }
    }

    private suspend fun checkSubscription(): String {
        return withContext(Dispatchers.IO) {
            try {
                val deviceId = getSecureValue("device_id") ?: return@withContext "auth_failed"
                val apiKey = getSecureValue("api_key") ?: return@withContext "auth_failed"

                val url = URL("https://api.vulcainvpn.com/api/subscription/$deviceId")
                val connection = url.openConnection() as HttpsURLConnection

                connection.requestMethod = "GET"
                connection.setRequestProperty("X-Api-Key", apiKey)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = 5000
                connection.readTimeout = 5000

                val responseCode = connection.responseCode
                VpnLogger.log(TAG, "Subscription check: HTTP $responseCode")

                when (responseCode) {
                    200 -> {
                        val response = connection.inputStream.bufferedReader().use { it.readText() }

                        if (response.trimStart().startsWith("<!DOCTYPE", ignoreCase = true) ||
                            response.trimStart().startsWith("<html", ignoreCase = true)) {
                            return@withContext "auth_failed"
                        }

                        val json = org.json.JSONObject(response)
                        val subscription = json.getJSONObject("subscription")
                        val status = subscription.getString("status")

                        VpnLogger.log(TAG, "Subscription status: $status")
                        return@withContext status
                    }
                    401, 403 -> return@withContext "auth_failed"
                    else -> return@withContext "unknown"
                }
            } catch (e: Exception) {
                VpnLogger.log(TAG, "Subscription check failed: ${e.message}")
                return@withContext "unknown"
            }
        }
    }

    private fun resetRetryState() {
        try {
            val retryPrefs = getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
            retryPrefs.edit()
                .putInt(KEY_RETRY_COUNT, 0)
                .putInt(KEY_RETRY_BATCH, 1)
                .putLong(KEY_LAST_RETRY_TIME, 0)
                .apply()
            VpnLogger.log(TAG, "🔄 Retry state reset")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to reset retry state", e)
        }
    }

    private fun getSecureValue(key: String): String? {
        return try {
            val masterKey = MasterKey.Builder(this)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                this,
                "FlutterSecureStorage",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            prefs.getString("${prefix}_${key}", null)
        } catch (e: Exception) {
            null
        }
    }

    private fun isAirplaneModeOn(): Boolean {
        return try {
            val value = Settings.Global.getInt(
                contentResolver,
                Settings.Global.AIRPLANE_MODE_ON,
                0
            )
            val isOn = value != 0
            VpnLogger.log(TAG, "✈️ Airplane mode check: $isOn")
            isOn
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error checking airplane mode", e)
            false
        }
    }

    private fun showDisconnectNotification(title: String, message: String) {
        try {
            VpnLogger.log(TAG, "📢 Showing disconnect notification: $title - $message")

            // ✅ Make the intent open the app and trigger reconnection
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("auto_reconnect_requested", true)  // ✅ Signal to Flutter to reconnect
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, DISCONNECT_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(message)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setOngoing(false)  // ✅ Not ongoing - user can dismiss
                .build()

            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(1001, notification)

            VpnLogger.log(TAG, "✅ Disconnect notification posted (ID: 1001)")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "❌ Failed to show notification", e)
        }
    }

    private fun isNetworkAvailable(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false

            val hasInternet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            val hasTransport = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                               caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                               caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

            hasInternet && hasTransport
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Network check error", e)
            false
        }
    }

    private fun getConfig(): String? {
        return try {
            val masterKey = MasterKey.Builder(this)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                this,
                "FlutterSecureStorage",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            prefs.getString("${prefix}_vpn_config", null)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Config retrieval error", e)
            null
        }
    }

    private fun startVpn(config: String) {
        try {
            val intent = Intent(this, MyVpnService::class.java).apply {
                putExtra("VPN_CONFIG", config)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            VpnLogger.log(TAG, "✅ VPN service start command sent")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to start VPN service", e)
        }
    }

    private fun isVpnRunning(): Boolean {
        return try {
            VpnLogger.log(TAG, "🔍 Checking VPN via network capabilities...")
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork)
            val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            VpnLogger.log(TAG, "✅ VPN running check: $isVpn")
            isVpn
        } catch (e: Exception) {
            VpnLogger.error(TAG, "VPN check error", e)
            false
        }
    }

    private fun success() {
        VpnLogger.log(TAG, "✅ Reconnection successful!")
        try {
            getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                .edit().putBoolean("has_unread_death", false).apply()
            val nm = getSystemService(NotificationManager::class.java)
            nm.cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Success cleanup error", e)
        }
        stopSelf()
    }

    private fun fail(reason: String) {
        VpnLogger.log(TAG, "❌ Reconnection failed: $reason")
        try {
            showFailNotification(reason)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to show notification", e)
        }
        stopSelf()
    }

    private fun showFailNotification(message: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("VPN Disconnected")
            .setContentText("$message - Tap to reconnect")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(1001, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(NotificationManager::class.java)

            val reconnectChannel = NotificationChannel(
                CHANNEL_ID,
                "VPN Auto-Reconnect",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when VPN is attempting to reconnect"
            }
            notificationManager.createNotificationChannel(reconnectChannel)

            val disconnectChannel = NotificationChannel(
                DISCONNECT_CHANNEL_ID,
                "VPN Disconnect Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Important alerts when VPN disconnects"
                enableVibration(true)
                setShowBadge(true)
            }
            notificationManager.createNotificationChannel(disconnectChannel)

            VpnLogger.log(TAG, "✅ Notification channels created")
        }
    }

    private fun createNotification(title: String, text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private suspend fun cleanupVpn() {
        VpnLogger.log(TAG, "🧹 Cleaning up existing VPN")
        try {
            startService(Intent(this, MyVpnService::class.java).apply {
                action = "STOP_VPN"
            })
            delay(2000)
            VpnLogger.log(TAG, "✅ Cleanup complete")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Cleanup error", e)
        }
    }

    private fun stopWatchdogService() {
        try {
            val intent = Intent(this, VpnWatchdogService::class.java)
            stopService(intent)
            VpnLogger.log(TAG, "✅ VPN watchdog service stopped")
            Log.d(TAG, "✅ VPN watchdog service stopped")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to stop watchdog", e)
            Log.e(TAG, "Failed to stop watchdog: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 AutoReconnectService onDestroy")
        reconnectJob?.cancel()
        serviceScope.cancel()
    }
}
