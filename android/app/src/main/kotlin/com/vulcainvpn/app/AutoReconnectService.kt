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
 * - Batch 1: 5 retries (1 min each = 5 min total)
 * - Batch 2: 5 retries (1 min each = 5 min total)
 * - Total: ~10 minutes before giving up permanently
 * - Reset counter after 8 minutes of stability OR on manual reconnect
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

        // ✅ FIX: Key to mark that a reconnect is in progress so watchdog
        // doesn't self-destruct when is_running is briefly false during cleanup.
        private const val KEY_RECONNECT_IN_PROGRESS = "reconnect_in_progress"
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

            stopForegroundCompat()
            stopWatchdogService()

            serviceScope.launch {
                cleanupVpn()
                val (title, message) = when (storedReason) {
                    "airplane_mode" -> Pair("VPN Disconnected", "Airplane mode enabled")
                    "subscription_expired" -> Pair("VPN Disconnected", "Subscription expired - Please reopen app")
                    "auth_required" -> Pair("VPN Disconnected", "Authentication required - Please login again")
                    "device_revoked" -> Pair("VPN Disconnected", "Device access revoked - Please login again")
                    else -> Pair("VPN Disconnected", "VPN stopped")
                }
                showDisconnectNotification(title, message)
                stopSelf()
            }
            return START_NOT_STICKY
        }

        // ⭐ Two-batch retry logic
        val retryPrefs = getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
        val lastRetryTime = retryPrefs.getLong(KEY_LAST_RETRY_TIME, 0)
        val now = System.currentTimeMillis()

        // Reset if enough time has passed since last attempt (stable period)
        if (now - lastRetryTime > RETRY_RESET_TIME_MS) {
            VpnLogger.log(TAG, "🔄 Resetting retry state (stable period elapsed)")
            retryPrefs.edit()
                .putInt(KEY_RETRY_COUNT, 0)
                .putInt(KEY_RETRY_BATCH, 1)
                .putLong(KEY_LAST_RETRY_TIME, now)
                .apply()
        }

        val currentRetryCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
        val currentRetryBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)

        // Check if we've exhausted all batches
        if (currentRetryBatch > MAX_BATCHES) {
            VpnLogger.log(TAG, "⛔ All retry batches exhausted - giving up permanently")

            stopForegroundCompat()
            showDisconnectNotification("VPN Disconnected", "Unable to reconnect - Please reconnect manually")
            stopWatchdogService()

            // Reset so next manual reconnect starts fresh
            resetRetryState()

            serviceScope.launch {
                cleanupVpn()
                showDisconnectNotification("VPN Disconnected", "Unable to reconnect - Please reconnect manually")
                stopSelf()
            }
            return START_NOT_STICKY
        }

        // Check if we need to wait between batches (cooldown)
        if (currentRetryCount >= MAX_RETRIES_PER_BATCH && currentRetryBatch == 1) {
            val timeSinceLastRetry = now - lastRetryTime

            if (timeSinceLastRetry < BATCH_COOLDOWN_MS) {
                val remainingCooldown = BATCH_COOLDOWN_MS - timeSinceLastRetry
                val remainingSeconds = (remainingCooldown / 1000).toInt()
                VpnLogger.log(TAG, "⏸️ Batch 1 complete - waiting ${remainingSeconds}s before batch 2")

                updateNotification("VPN Reconnecting", "Retrying in ${remainingSeconds}s...")

                mainHandler.postDelayed({
                    VpnLogger.log(TAG, "⏰ Cooldown complete - starting batch 2")
                    retryPrefs.edit()
                        .putInt(KEY_RETRY_BATCH, 2)
                        .putInt(KEY_RETRY_COUNT, 0)
                        .putLong(KEY_LAST_RETRY_TIME, System.currentTimeMillis())
                        .apply()

                    val retryIntent = Intent(this, AutoReconnectService::class.java).apply {
                        putExtra("reason", reason)
                    }
                    startServiceCompat(retryIntent)
                }, remainingCooldown)

                return START_NOT_STICKY
            } else {
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
                VpnLogger.log(TAG, "⛔ All batches complete - giving up")
                stopForegroundCompat()
                showDisconnectNotification("VPN Disconnected", "Unable to reconnect - Please reconnect manually")
                resetRetryState()
                stopSelf()
                return START_NOT_STICKY
            } else {
                retryPrefs.edit().putLong(KEY_LAST_RETRY_TIME, now).apply()
                stopSelf()
                mainHandler.postDelayed({
                    startServiceCompat(Intent(this, AutoReconnectService::class.java).apply {
                        putExtra("reason", reason)
                    })
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
                withContext(Dispatchers.Main) { fail("Error: ${e.message}") }
            }
        }

        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun updateNotification(title: String, message: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, createNotification(title, message))
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to update notification", e)
        }
    }

    private suspend fun performReconnection(reason: String, batch: Int, attempt: Int) {
        VpnLogger.log(TAG, "🚀 Starting reconnection (reason: $reason, batch: $batch, attempt: $attempt/$MAX_RETRIES_PER_BATCH)")

        try {
            // Check airplane mode first
            if (isAirplaneModeOn()) {
                VpnLogger.log(TAG, "✈️ Airplane mode detected - stopping")
                stopForegroundCompat()
                stopWatchdogService()
                cleanupVpn()
                showDisconnectNotification("VPN Disconnected", "Airplane mode enabled")
                resetRetryState()
                stopSelf()
                return
            }

            // ✅ FIX: Set reconnect_in_progress flag BEFORE cleanup so the watchdog
            // (separate process) knows is_running=false is intentional and won't self-destruct.
            setReconnectInProgress(true)

            VpnLogger.log(TAG, "🧹 Cleaning up VPN")
            cleanupVpn()
            VpnLogger.log(TAG, "✅ Cleanup complete")

            VpnLogger.log(TAG, "🔄 Attempting reconnection (1 min timeout)")

            val startTime = System.currentTimeMillis()
            val maxRetryTime = 1 * 60 * 1000L
            var subAttempt = 0

            while (System.currentTimeMillis() - startTime < maxRetryTime) {
                subAttempt++

                if (isAirplaneModeOn()) {
                    VpnLogger.log(TAG, "✈️ Airplane mode enabled during reconnect")
                    stopForegroundCompat()
                    showDisconnectNotification("VPN Disconnected", "Airplane mode enabled")
                    setReconnectInProgress(false)
                    resetRetryState()
                    stopSelf()
                    return
                }

                // Check subscription every 30 seconds (every 3rd sub-attempt)
                if (subAttempt % 3 == 0) {
                    VpnLogger.log(TAG, "🔐 Checking subscription status...")
                    val subscriptionStatus = checkSubscription()

                    when (subscriptionStatus) {
                        "expired", "canceled" -> {
                            VpnLogger.log(TAG, "⛔ Subscription expired during reconnect - stopping")
                            stopForegroundCompat()
                            stopWatchdogService()
                            cleanupVpn()
                            showDisconnectNotification("VPN Disconnected", "Subscription expired")
                            setReconnectInProgress(false)
                            resetRetryState()
                            stopSelf()
                            return
                        }
                        "auth_failed" -> {
                            VpnLogger.log(TAG, "⛔ Auth failed during reconnect - stopping")
                            stopForegroundCompat()
                            stopWatchdogService()
                            cleanupVpn()
                            showDisconnectNotification("VPN Disconnected", "Authentication failed - Please login again")
                            setReconnectInProgress(false)
                            resetRetryState()
                            stopSelf()
                            return
                        }
                        "active" -> VpnLogger.log(TAG, "✅ Subscription still active")
                    }
                }

                if (isNetworkAvailable()) {
                    VpnLogger.log(TAG, "✅ Network available - attempting connection (sub-attempt $subAttempt)")

                    val config = getConfig()
                    if (config == null) {
                        VpnLogger.log(TAG, "❌ No config available")
                        setReconnectInProgress(false)
                        fail("No configuration")
                        return
                    }

                    startVpn(config)
                    delay(10000)

                    if (isVpnRunning()) {
                        VpnLogger.log(TAG, "✅ Reconnected successfully! (batch $batch, attempt $attempt)")
                        // ✅ FIX: Clear reconnect flag and reset batch counter on success.
                        // Without this, the next VPN death would immediately see
                        // "all batches exhausted" and give up with zero retries.
                        setReconnectInProgress(false)
                        success()
                        return
                    }

                    // Check if failure was due to authentication
                    val vpnStatePrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    val deathReason = vpnStatePrefs.getString("death_reason", "")

                    if (deathReason == "auth_required" || deathReason == "device_revoked" || deathReason == "credentials_expired") {
                        VpnLogger.log(TAG, "⛔ Authentication failed - credentials expired/invalid")
                        stopForegroundCompat()
                        stopWatchdogService()
                        cleanupVpn()
                        showDisconnectNotification("VPN Disconnected", "Please reconnect manually to refresh credentials")
                        setReconnectInProgress(false)
                        resetRetryState()
                        stopSelf()
                        return
                    }
                }

                VpnLogger.log(TAG, "⏳ Retrying in 10s... (sub-attempt $subAttempt)")
                delay(10000)
            }

            // 1 minute passed — clear reconnect flag regardless of outcome
            setReconnectInProgress(false)

            VpnLogger.log(TAG, "⏱️ 1 minute passed for batch $batch, attempt $attempt")
            stopForegroundCompat()

            val retryPrefs = getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
            val currentCount = retryPrefs.getInt(KEY_RETRY_COUNT, 0)
            val currentBatch = retryPrefs.getInt(KEY_RETRY_BATCH, 1)

            if (currentCount >= MAX_RETRIES_PER_BATCH && currentBatch >= MAX_BATCHES) {
                VpnLogger.log(TAG, "⛔ All batches exhausted - stopping permanently")
                stopWatchdogService()
                cleanupVpn()
                showDisconnectNotification("VPN Disconnected", "Unable to reconnect - Please reconnect manually")
                resetRetryState()
                stopSelf()
            } else if (currentCount >= MAX_RETRIES_PER_BATCH && currentBatch == 1) {
                VpnLogger.log(TAG, "⏸️ Batch 1 complete - scheduling cooldown")
                showDisconnectNotification("VPN Reconnecting", "Retrying in 2 minutes...")

                withContext(Dispatchers.Main) {
                    mainHandler.postDelayed({
                        VpnLogger.log(TAG, "⏰ Cooldown complete - starting batch 2")
                        startServiceCompat(Intent(this@AutoReconnectService, AutoReconnectService::class.java).apply {
                            putExtra("reason", reason)
                        })
                    }, BATCH_COOLDOWN_MS)
                }
                stopSelf()
            } else {
                VpnLogger.log(TAG, "🔄 Scheduling next retry (batch $currentBatch, attempt ${currentCount + 1}/$MAX_RETRIES_PER_BATCH)")
                showDisconnectNotification("VPN Reconnecting", "Next retry in 10s... (batch $currentBatch, $currentCount/$MAX_RETRIES_PER_BATCH)")

                withContext(Dispatchers.Main) {
                    mainHandler.postDelayed({
                        VpnLogger.log(TAG, "🚀 Starting next retry attempt")
                        startServiceCompat(Intent(this@AutoReconnectService, AutoReconnectService::class.java).apply {
                            putExtra("reason", reason)
                        })
                    }, 10000)
                }
                stopSelf()
            }

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Reconnection failed", e)
            setReconnectInProgress(false)
            fail("Reconnection error: ${e.message}")
        }
    }

    // ✅ FIX: Set/clear the reconnect_in_progress flag so VpnWatchdogService (separate
    // process) can distinguish "is_running=false because cleanup" from "VPN actually died".
    // The watchdog checks this before self-destructing on shouldBeRunning=false.
    private fun setReconnectInProgress(inProgress: Boolean) {
        try {
            getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_RECONNECT_IN_PROGRESS, inProgress)
                .apply()
            VpnLogger.log(TAG, if (inProgress) "🔄 Reconnect in progress flag SET" else "✅ Reconnect in progress flag CLEARED")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to set reconnect flag", e)
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
            getSharedPreferences(PREFS_RETRY_NAME, Context.MODE_PRIVATE)
                .edit()
                .putInt(KEY_RETRY_COUNT, 0)
                .putInt(KEY_RETRY_BATCH, 1)
                .putLong(KEY_LAST_RETRY_TIME, System.currentTimeMillis())
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
            val value = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0)
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

            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("auto_reconnect_requested", true)
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
                .setOngoing(false)
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
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
             caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
             caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
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

    private suspend fun isVpnRunning(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val activeNetwork = cm.activeNetwork ?: return false
        val hasVpn = cm.getNetworkCapabilities(activeNetwork)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        if (!hasVpn) return false

        // Interface up != tunnel working. Prove it carries traffic.
        return withContext(Dispatchers.IO) {
            try {
                val deviceId = getSecureValue("device_id") ?: return@withContext false
                val apiKey = getSecureValue("api_key") ?: return@withContext false
                val conn = URL("https://api.vulcainvpn.com/api/heartbeat/$deviceId")
                    .openConnection() as HttpsURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("X-Api-Key", apiKey)
                conn.connectTimeout = 5000
                conn.readTimeout = 5000
                conn.responseCode
                conn.disconnect()
                VpnLogger.log(TAG, "✅ VPN verified: tunnel carries traffic")
                true
            } catch (e: Exception) {
                VpnLogger.log(TAG, "❌ VPN transport up but no traffic: ${e.message}")
                false
            }
        }
    }

    private fun success() {
        VpnLogger.log(TAG, "✅ Reconnection successful!")
        try {
            getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                .edit().putBoolean("has_unread_death", false).apply()

            // ✅ FIX: Reset the batch counter after a successful reconnect.
            // Without this, the next VPN death immediately finds retry_batch > MAX_BATCHES
            // and gives up with zero retry attempts, showing "unable to reconnect" instantly.
            resetRetryState()

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
            val nm = getSystemService(NotificationManager::class.java)

            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "VPN Auto-Reconnect", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shows when VPN is attempting to reconnect" })

            nm.createNotificationChannel(NotificationChannel(
                DISCONNECT_CHANNEL_ID, "VPN Disconnect Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Important alerts when VPN disconnects"
                enableVibration(true)
                setShowBadge(true)
            })

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
            stopService(Intent(this, VpnWatchdogService::class.java))
            VpnLogger.log(TAG, "✅ VPN watchdog service stopped")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to stop watchdog", e)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun startServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 AutoReconnectService onDestroy")
        reconnectJob?.cancel()
        serviceScope.cancel()

        // ✅ SAFETY: Always clear the reconnect_in_progress flag on destroy.
        // If the OS kills this service mid-reconnect (low memory, etc.), the flag
        // would otherwise stay true forever, keeping the watchdog alive indefinitely.
        // The watchdog's next check will then correctly see is_running=false and stop.
        setReconnectInProgress(false)
    }
}
