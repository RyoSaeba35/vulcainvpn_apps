package com.example.cross_platform_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.*

/**
 * ✅ FIXED: "Broadcast First, Think Later" + Automatic Network Recovery + Token Management
 *
 * Key behavior: Service STAYS ALIVE when network is down, waiting for NetworkCallback.
 * When network recovers, automatically reconnects WITHOUT user intervention.
 */
class AutoReconnectService : Service() {

    companion object {
        private const val TAG = "AutoReconnectService"
        private const val NOTIFICATION_ID = 2000
        private const val CHANNEL_ID = "auto_reconnect"
        private const val MAX_ATTEMPTS = 5
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var reconnectJob: Job? = null

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var waitingForNetwork = false

    override fun onCreate() {
        super.onCreate()
        VpnLogger.log(TAG, "📦 AutoReconnectService onCreate")
        createNotificationChannel()

        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnLogger.log(TAG, "🔄 AutoReconnectService.onStartCommand")
        Log.d(TAG, "🔄 Auto-reconnect service started")

        try {
            val notification = createNotification("Reconnecting VPN", "Checking network...")
            startForeground(NOTIFICATION_ID, notification)
            VpnLogger.log(TAG, "✅ Started foreground with notification ID $NOTIFICATION_ID")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to start foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }

        val reason = intent?.getStringExtra("reason") ?: "unknown"
        VpnLogger.log(TAG, "Death reason: $reason")

        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
        val storedReason = prefs.getString("death_reason", "")
        if (storedReason == "subscription_expired" || storedReason == "auth_required") {
            VpnLogger.log(TAG, "⛔ Subscription expired or auth required - stopping service immediately")
            stopSelf()
            return START_NOT_STICKY
        }

        // Reset waiting flag on new start
        waitingForNetwork = false

        reconnectJob?.cancel()

        reconnectJob = serviceScope.launch(Dispatchers.IO) {
            try {
                performReconnection(reason)
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

    private fun registerNetworkCallback() {
        try {
            val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

            val networkRequest = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
                .build()

            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    super.onAvailable(network)

                    if (waitingForNetwork) {
                        VpnLogger.log(TAG, "🔄 Network recovered! Restarting reconnection...")
                        Log.d(TAG, "🔄 Network available - restarting reconnection")

                        waitingForNetwork = false

                        reconnectJob?.cancel()
                        reconnectJob = serviceScope.launch(Dispatchers.IO) {
                            try {
                                performReconnection("network_recovered")
                            } catch (e: Exception) {
                                VpnLogger.error(TAG, "Exception in performReconnection after network recovery", e)
                                withContext(Dispatchers.Main) {
                                    fail("Error: ${e.message}")
                                }
                            }
                        }
                    }
                }

                override fun onLost(network: Network) {
                    super.onLost(network)
                    VpnLogger.log(TAG, "📶 Network lost")
                    Log.d(TAG, "📶 Network lost")
                }
            }

            connectivityManager.registerNetworkCallback(networkRequest, networkCallback!!)
            VpnLogger.log(TAG, "✅ NetworkCallback registered")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to register NetworkCallback", e)
        }
    }

    private fun unregisterNetworkCallback() {
        try {
            networkCallback?.let {
                val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                connectivityManager.unregisterNetworkCallback(it)
                VpnLogger.log(TAG, "✅ NetworkCallback unregistered")
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to unregister NetworkCallback", e)
        }
        networkCallback = null
    }

    private suspend fun performReconnection(reason: String) {
        VpnLogger.log(TAG, "🚀 Starting reconnection flow (reason: $reason)")
        Log.d(TAG, "Starting reconnection (reason: $reason)")

        try {
            // STEP 1: Clean up broken tunnel
            VpnLogger.log(TAG, "STEP 1: Cleaning up VPN")
            cleanupVpn()

            // STEP 2: Wait for network
            VpnLogger.log(TAG, "STEP 2: Waiting for network")
            if (!waitForNetwork()) {
                VpnLogger.log(TAG, "❌ No network available")

                waitingForNetwork = true
                VpnLogger.log(TAG, "🔔 Keeping service alive - NetworkCallback will restart when network recovers")

                updateNotification("Waiting for network", "VPN will reconnect when internet is available")

                return
            }
            VpnLogger.log(TAG, "✅ Network available")

            // STEP 3: Check subscription (ALWAYS, even for vpn_broken)
            VpnLogger.log(TAG, "STEP 3: Checking subscription status")
            val subStatus = checkSubscription()
            VpnLogger.log(TAG, "Subscription status: $subStatus")

            when (subStatus) {
                "expired", "canceled" -> {
                    VpnLogger.log(TAG, "❌ Subscription not active ($subStatus)")
                    VpnLogger.log(TAG, "📝 Updating death reason to subscription_expired to prevent loops")

                    updateDeathReason("subscription_expired", "Your VPN subscription has expired")

                    val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                    val appProcesses = activityManager.runningAppProcesses
                    var isForeground = false

                    appProcesses?.forEach { processInfo ->
                        if (processInfo.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
                            processInfo.processName == packageName) {
                            isForeground = true
                        }
                    }

                    if (!isForeground) {
                        VpnLogger.log(TAG, "📱 App is in background - showing subscription notification")
                        try {
                            val intent = Intent(this, MainActivity::class.java).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                            }
                            val pendingIntent = PendingIntent.getActivity(
                                this, 0, intent,
                                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                            )

                            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                                .setContentTitle("Subscription Expired")
                                .setContentText("Your VPN subscription has expired. Tap to renew.")
                                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                                .setContentIntent(pendingIntent)
                                .setAutoCancel(true)
                                .setPriority(NotificationCompat.PRIORITY_HIGH)
                                .build()

                            val nm = getSystemService(NotificationManager::class.java)
                            nm.notify(1002, notification)
                            VpnLogger.log(TAG, "✅ Subscription expired notification shown")
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to show subscription notification", e)
                        }
                    } else {
                        VpnLogger.log(TAG, "📱 App is in foreground - Flutter will show dialog, skipping notification")
                    }

                    VpnLogger.log(TAG, "🛑 Stopping AutoReconnectService (subscription expired)")
                    stopSelf()
                    return
                }
                "auth_failed" -> {
                    // ✅ NEW: Token invalid - tell user to re-login
                    VpnLogger.log(TAG, "❌ Authentication failed - token invalid")
                    updateDeathReason("auth_required", "Session expired - please login again")

                    // Show notification
                    val intent = Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    val pendingIntent = PendingIntent.getActivity(
                        this, 0, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )

                    val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                        .setContentTitle("Session Expired")
                        .setContentText("Please login again to continue.")
                        .setSmallIcon(android.R.drawable.ic_dialog_alert)
                        .setContentIntent(pendingIntent)
                        .setAutoCancel(true)
                        .setPriority(NotificationCompat.PRIORITY_HIGH)
                        .build()

                    val nm = getSystemService(NotificationManager::class.java)
                    nm.notify(1003, notification)

                    VpnLogger.log(TAG, "🛑 Stopping AutoReconnectService (auth required)")
                    stopSelf()
                    return
                }
                "active" -> {
                    VpnLogger.log(TAG, "✅ Subscription is active")
                }
                else -> {
                    VpnLogger.log(TAG, "⚠️ Subscription status unknown - proceeding with caution")
                }
            }

            // STEP 4: Get config
            VpnLogger.log(TAG, "STEP 4: Getting VPN config")
            val config = getConfig()
            if (config == null) {
                VpnLogger.log(TAG, "❌ No config available")
                fail("No configuration")
                return
            }
            VpnLogger.log(TAG, "✅ Config retrieved (${config.length} chars)")

            // STEP 5: Retry loop
            VpnLogger.log(TAG, "STEP 5: Starting reconnection attempts")
            val delays = listOf(0L, 3000L, 6000L, 10000L, 15000L)

            for (i in 1..MAX_ATTEMPTS) {
                VpnLogger.log(TAG, "🔄 Reconnection attempt $i of $MAX_ATTEMPTS")
                updateNotification("Reconnecting...", "Attempt $i of $MAX_ATTEMPTS")

                if (i > 1) {
                    val delayMs = delays.getOrElse(i - 1) { 15000 }
                    VpnLogger.log(TAG, "⏳ Waiting ${delayMs}ms before retry")
                    delay(delayMs)
                }

                if (!isNetworkAvailable()) {
                    VpnLogger.log(TAG, "⚠️ Network lost during reconnection")

                    waitingForNetwork = true
                    VpnLogger.log(TAG, "🔔 Network lost - keeping service alive, waiting for recovery")
                    updateNotification("Waiting for network", "VPN will reconnect when internet is available")
                    return
                }

                VpnLogger.log(TAG, "🚀 Starting VPN service")
                startVpn(config)

                VpnLogger.log(TAG, "⏳ Waiting 10s for VPN to connect")
                delay(10000)

                if (isVpnRunning()) {
                    VpnLogger.log(TAG, "✅ VPN is running - reconnection successful!")
                    success()
                    return
                } else {
                    VpnLogger.log(TAG, "❌ VPN not running after attempt $i")
                }
            }

            // All attempts failed
            VpnLogger.log(TAG, "❌ All $MAX_ATTEMPTS reconnection attempts failed")
            fail("Could not reconnect after $MAX_ATTEMPTS attempts")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Reconnection failed with exception", e)
            Log.e(TAG, "Reconnection failed: ${e.message}")
            fail("Reconnection error: ${e.message}")
        }
    }

    private suspend fun cleanupVpn() {
        VpnLogger.log(TAG, "🧹 Cleaning up existing VPN")
        try {
            startService(Intent(this, MyVpnService::class.java).apply { action = "STOP_VPN" })
            delay(1000)
            VpnLogger.log(TAG, "✅ Cleanup complete")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Cleanup error", e)
        }
    }

    private suspend fun waitForNetwork(): Boolean {
        VpnLogger.log(TAG, "📶 Waiting for network (max 10 seconds)")
        repeat(10) { attempt ->
            if (isNetworkAvailable()) {
                VpnLogger.log(TAG, "✅ Network detected on attempt ${attempt + 1}")
                delay(2000) // Extra delay for DNS
                return true
            }
            VpnLogger.log(TAG, "⏳ Network check ${attempt + 1}/10")
            delay(1000)
        }
        VpnLogger.log(TAG, "❌ Network not available after 10 attempts")
        return false
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

    private suspend fun checkSubscription(): String {
        VpnLogger.log(TAG, "🔐 Checking subscription status via API")
        return withContext(Dispatchers.IO) {
            try {
                val accessToken = getSecureValue("access_token")
                if (accessToken == null) {
                    VpnLogger.log(TAG, "⚠️ No access token found")
                    return@withContext "unknown"
                }

                VpnLogger.log(TAG, "Making API request to check subscription...")
                val url = java.net.URL("https://api.vulcainvpn.com/api/subscription")
                val connection = url.openConnection() as javax.net.ssl.HttpsURLConnection

                connection.requestMethod = "GET"
                connection.setRequestProperty("Authorization", "Bearer $accessToken")
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = 10000
                connection.readTimeout = 10000

                val responseCode = connection.responseCode
                VpnLogger.log(TAG, "Subscription API response code: $responseCode")

                when (responseCode) {
                    200 -> {
                        val response = connection.inputStream.bufferedReader().use { it.readText() }
                        VpnLogger.log(TAG, "API response body: ${response.take(200)}...")

                        // Detect HTML response
                        if (response.trimStart().startsWith("<!DOCTYPE", ignoreCase = true) ||
                            response.trimStart().startsWith("<html", ignoreCase = true)) {
                            VpnLogger.log(TAG, "⚠️ API returned HTML - auth failed")
                            return@withContext "auth_failed"
                        }

                        val json = org.json.JSONObject(response)
                        val subscription = json.getJSONObject("subscription")
                        val status = subscription.getString("status")

                        VpnLogger.log(TAG, "✅ Subscription status from API: $status")
                        return@withContext status
                    }
                    401, 403 -> {
                        VpnLogger.log(TAG, "⚠️ Authentication failed ($responseCode)")
                        return@withContext "auth_failed"  // ← CHANGED from "expired"
                    }
                    else -> {
                        VpnLogger.log(TAG, "⚠️ Unexpected response code: $responseCode")
                        return@withContext "unknown"
                    }
                }
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Subscription check failed", e)
                return@withContext "unknown"
            }
        }
    }

    private fun updateDeathReason(newReason: String, newMessage: String) {
        VpnLogger.log(TAG, "📝 Updating death reason to: $newReason")
        VpnLogger.log(TAG, "This prevents infinite reconnection loops")
        try {
            val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString("death_reason", newReason)
                putString("death_message", newMessage)
                putLong("death_timestamp", System.currentTimeMillis())
                putBoolean("has_unread_death", true)
                apply()
            }
            VpnLogger.log(TAG, "✅ Death reason updated successfully")
            VpnLogger.log(TAG, "VpnDeathReceiver will now reject future reconnect attempts")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to update death reason", e)
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

    private fun getSecureValue(key: String): String? {
        return try {
            val masterKey = MasterKey.Builder(this)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            val encryptedPrefs = EncryptedSharedPreferences.create(
                this,
                "FlutterSecureStorage",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            val fullKey = "${prefix}_${key}"
            encryptedPrefs.getString(fullKey, null)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Secure value retrieval error", e)
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
            val activeNetwork = cm.activeNetwork

            if (activeNetwork == null) {
                VpnLogger.log(TAG, "No active network")
                return false
            }

            val caps = cm.getNetworkCapabilities(activeNetwork)
            val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

            VpnLogger.log(TAG, "✅ VPN running check: $isVpn")
            isVpn
        } catch (e: Exception) {
            VpnLogger.error(TAG, "VPN check error", e)
            false
        }
    }

    private suspend fun updateNotification(title: String, text: String) {
        withContext(Dispatchers.Main) {
            try {
                val nm = getSystemService(NotificationManager::class.java)
                nm.notify(NOTIFICATION_ID, createNotification(title, text))
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Notification update error", e)
            }
        }
    }

    private fun success() {
        VpnLogger.log(TAG, "✅ Reconnection successful!")
        Log.d(TAG, "✅ Success!")
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
        Log.e(TAG, "❌ Failed: $reason")
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
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(1001, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN Auto-Reconnect",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
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

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 AutoReconnectService onDestroy")

        unregisterNetworkCallback()

        reconnectJob?.cancel()
        serviceScope.cancel()
    }
}
