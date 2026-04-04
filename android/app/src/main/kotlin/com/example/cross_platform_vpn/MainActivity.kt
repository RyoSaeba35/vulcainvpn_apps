package com.example.cross_platform_vpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Handler
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.content.Context
import android.app.NotificationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.content.BroadcastReceiver
import android.content.IntentFilter
import kotlinx.coroutines.*
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class MainActivity : FlutterActivity() {

    private val CONTROL_CHANNEL = "com.vulcain.vpn/control"
    private val STATUS_CHANNEL = "com.vulcain.vpn/status"

    private val VPN_REQUEST_CODE = 1001
    private val NOTIFICATION_REQUEST_CODE = 1002
    private val TAG = "MainActivity"

    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null

    companion object {
        var statusSink: EventChannel.EventSink? = null
    }

    private var vpnDeathReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ✅ NEW: Check if opened from notification
        handleNotificationIntent(intent)

        // ✅ Register broadcast receiver for VPN death events
        vpnDeathReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == "com.vulcain.vpn.VPN_DIED") {
                    val reason = intent.getStringExtra("reason") ?: "unknown"
                    val message = intent.getStringExtra("message") ?: "VPN died"
                    val timestamp = intent.getLongExtra("timestamp", 0)

                    Log.d(TAG, "📻 Received VPN_DIED broadcast: $reason")

                    // ✅ Store death event first (backup)
                    try {
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        prefs.edit().apply {
                            putString("death_reason", reason)
                            putString("death_message", message)
                            putLong("death_timestamp", timestamp)
                            putBoolean("has_unread_death", true)
                            apply()
                        }
                        Log.d(TAG, "   ✅ Stored death event in SharedPreferences")
                    } catch (e: Exception) {
                        Log.e(TAG, "   ❌ Failed to store death event", e)
                    }

                    // ✅ Try to send via EventSink (if Flutter is running)
                    if (statusSink != null) {
                        statusSink?.success(mapOf(
                            "event" to "vpn_died",
                            "reason" to reason,
                            "message" to message,
                            "timestamp" to timestamp
                        ))
                        Log.d(TAG, "   ✅ Sent to Flutter via EventSink")
                    }

                    // ✅ NEW: Check if auto-reconnect is enabled
                    val settingsPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val autoReconnectKey = "flutter.auto_reconnect_enabled"
                    val autoReconnectEnabled = settingsPrefs.getBoolean(autoReconnectKey, true)

                    Log.d(TAG, "   🔄 Auto-reconnect enabled: $autoReconnectEnabled")

                    // ✅ NEW: Check if reason is reconnectable
                    val isReconnectable = when (reason) {
                        "service_killed" -> true
                        "process_crashed" -> true
                        "vpn_broken" -> true
                        "subscription_expired" -> true
                        "permission_revoked" -> false // User action required
                        else -> false
                    }

                    Log.d(TAG, "   🔄 Reason reconnectable: $isReconnectable")

                    // ✅ NEW: Trigger auto-reconnect in background
                    if (autoReconnectEnabled && isReconnectable) {
                        Log.d(TAG, "   🔄 Starting background auto-reconnect...")
                        startBackgroundAutoReconnect(reason, message)
                    } else {
                        Log.d(TAG, "   ⏸️ Skipping auto-reconnect (disabled or not reconnectable)")
                    }
                }
            }
        }

        val filter = IntentFilter("com.vulcain.vpn.VPN_DIED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(vpnDeathReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(vpnDeathReceiver, filter)
        }
        Log.d(TAG, "✅ Registered VPN death broadcast receiver")
    }

    // ✅ NEW: Handle notification tap when app already running
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    // ✅ NEW: Handle auto-reconnect in background (native)
    private fun startBackgroundAutoReconnect(reason: String, message: String) {
        Thread {
            val maxAttempts = 4
            val delays = listOf(0, 5000, 10000, 15000) // ms: 0s, 5s, 10s, 15s

            for (attempt in 1..maxAttempts) {
                Log.d(TAG, "🔄 Auto-reconnect attempt $attempt/$maxAttempts")

                // Wait before retry (except first attempt)
                if (delays[attempt - 1] > 0) {
                    Log.d(TAG, "   ⏳ Waiting ${delays[attempt - 1] / 1000}s before retry...")
                    Thread.sleep(delays[attempt - 1].toLong())
                }

                try {
                    // Step 1: Check subscription status
                    Log.d(TAG, "   🔍 Checking subscription status...")
                    val subscriptionStatus = runBlocking {
                        checkSubscriptionStatus()
                    }

                    if (subscriptionStatus == "expired") {
                        Log.d(TAG, "   🔴 Subscription expired - stopping auto-reconnect")

                        // Update stored event to show subscription expired
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        prefs.edit().apply {
                            putString("death_reason", "subscription_expired")
                            putString("death_message", "Your VPN subscription has expired")
                            apply()
                        }

                        // Show notification
                        showReconnectNotification(
                            "Subscription Expired",
                            "Your VPN subscription has expired. Tap to renew."
                        )
                        return@Thread
                    }

                    if (subscriptionStatus != "active") {
                        Log.d(TAG, "   ⚠️ Unknown subscription status: $subscriptionStatus")
                        continue // Retry
                    }

                    Log.d(TAG, "   ✅ Subscription active, attempting reconnect...")

                    // Step 2: Get VPN config from secure storage
                    val masterKey = MasterKey.Builder(applicationContext)
                        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                        .build()

                    val encryptedPrefs = EncryptedSharedPreferences.create(
                        applicationContext,
                        "FlutterSecureStorage",
                        masterKey,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                    )

                    val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
                    val vpnConfig = encryptedPrefs.getString("${prefix}_vpn_config", null)

                    if (vpnConfig == null) {
                        Log.e(TAG, "   ❌ No VPN config found")
                        continue
                    }

                    // Step 3: Start VPN service
                    Handler(Looper.getMainLooper()).post {
                        try {
                            val intent = Intent(this, MyVpnService::class.java).apply {
                                putExtra("VPN_CONFIG", vpnConfig)
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }

                            Log.d(TAG, "   🚀 VPN service start requested")
                        } catch (e: Exception) {
                            Log.e(TAG, "   ❌ Error starting VPN: ${e.message}", e)
                        }
                    }

                    // Wait for VPN to start
                    Thread.sleep(2000)

                    // Step 4: Verify VPN started
                    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val activeNetwork = connectivityManager.activeNetwork
                    val caps = activeNetwork?.let {
                        connectivityManager.getNetworkCapabilities(it)
                    }
                    val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                    if (isVpn) {
                        Log.d(TAG, "   ✅ Auto-reconnect SUCCESS on attempt $attempt")

                        // Clear death event
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        prefs.edit().apply {
                            putBoolean("has_unread_death", false)
                            apply()
                        }

                        // Cancel any notifications
                        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        notificationManager.cancel(1001)

                        // Notify Flutter if running
                        if (statusSink != null) {
                            Handler(Looper.getMainLooper()).post {
                                statusSink?.success(mapOf(
                                    "event" to "auto_reconnect_success",
                                    "attempt" to attempt
                                ))
                            }
                        }

                        return@Thread // Success!
                    } else {
                        Log.d(TAG, "   ❌ VPN not active after attempt $attempt")
                        continue
                    }

                } catch (e: Exception) {
                    Log.e(TAG, "   ❌ Auto-reconnect attempt $attempt failed: ${e.message}", e)
                    continue
                }
            }

            // ❌ All attempts failed
            Log.d(TAG, "🔴 Auto-reconnect FAILED after $maxAttempts attempts")

            // Show notification
            showReconnectNotification(
                when (reason) {
                    "service_killed" -> "VPN Service Stopped"
                    "process_crashed" -> "VPN Crashed"
                    "vpn_broken" -> "VPN Connection Lost"
                    else -> "VPN Disconnected"
                },
                "Could not reconnect automatically. Tap to try again."
            )

        }.start()
    }

    // ✅ NEW: Show notification helper
    private fun showReconnectNotification(title: String, message: String) {
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Create notification channel (Android O+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = android.app.NotificationChannel(
                    "vpn_status",
                    "VPN Status",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "VPN connection status notifications"
                    enableVibration(true)
                }
                notificationManager.createNotificationChannel(channel)
            }

            // Build notification
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = android.app.PendingIntent.getActivity(
                this,
                0,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.app.Notification.Builder(this, "vpn_status")
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(this)
            }
                .setContentTitle(title)
                .setContentText(message)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .build()

            notificationManager.notify(1001, notification)
            Log.d(TAG, "📬 Notification shown: $title")

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error showing notification: ${e.message}", e)
        }
    }

    // ✅ NEW: Handle opening from notification
    private fun handleNotificationIntent(intent: Intent?) {
        // If user tapped notification, check for death events after Flutter initializes
        if (intent?.action == Intent.ACTION_MAIN) {
            Log.d(TAG, "📱 App opened from notification - will check for death events")

            // Give Flutter time to initialize, then check for death events
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    val channel = flutterEngine?.dartExecutor?.binaryMessenger
                    if (channel != null) {
                        MethodChannel(channel, CONTROL_CHANNEL)
                            .invokeMethod("checkForDeathEvents", null)
                        Log.d(TAG, "✅ Triggered death event check from notification")
                    } else {
                        Log.w(TAG, "⚠️ Flutter not ready yet, death check will happen on resume")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error checking death events from notification: $e")
                }
            }, 500) // 500ms delay to ensure Flutter is ready
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONTROL_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        result.success(notificationManager.areNotificationsEnabled())
                    } else {
                        result.success(true)
                    }
                }
                "checkVpnPermission" -> {
                    val intent = VpnService.prepare(this)
                    result.success(intent == null)
                }
                "getPackageName" -> getPackageName(result)
                "startVpn" -> {
                    val configJson = call.argument<String>("config")

                    if (configJson == null) {
                        result.error("NO_CONFIG", "Config not provided", null)
                        return@setMethodCallHandler
                    }

                    pendingResult = result
                    pendingConfig = configJson

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                NOTIFICATION_REQUEST_CODE
                            )
                            return@setMethodCallHandler
                        }
                    }
                    requestVpnPermission()
                }
                "stopVpn" -> stopVpnInternal(result)
                "getStatus" -> {
                    val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    val isRunning = prefs.getBoolean("is_running", false)
                    result.success(isRunning)
                }
                "getStartTime" -> {
                    val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    val startTime = prefs.getLong("start_time", 0)
                    result.success(if (startTime > 0) startTime else null)
                }
                // ✅ PRIORITY 1: New method to verify VPN is actually active
                "isVpnActive" -> {
                    try {
                        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val activeNetwork = connectivityManager.activeNetwork

                        if (activeNetwork == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                        val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                        Log.d(TAG, "🔍 VPN active check: $isVpn")
                        result.success(isVpn)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error checking VPN active state", e)
                        result.success(false)
                    }
                }
                // ✅ PRIORITY 1: Clear stale VPN state
                "clearVpnState" -> {
                    try {
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        prefs.edit().clear().apply()
                        Log.d(TAG, "✅ Cleared stale VPN state")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error clearing VPN state", e)
                        result.error("CLEAR_FAILED", e.message, null)
                    }
                }
                "checkForDeathEvents" -> {
                    try {
                        Log.d(TAG, "🔍 Checking for stored death events...")

                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        val hasUnreadDeath = prefs.getBoolean("has_unread_death", false)

                        Log.d(TAG, "   has_unread_death: $hasUnreadDeath")

                        if (hasUnreadDeath) {
                            val reason = prefs.getString("death_reason", "unknown")
                            val message = prefs.getString("death_message", "VPN died unexpectedly")
                            val timestamp = prefs.getLong("death_timestamp", 0)

                            Log.d(TAG, "   reason: $reason")
                            Log.d(TAG, "   message: $message")

                            val deathEvent = mapOf(
                                "reason" to reason,
                                "message" to message,
                                "timestamp" to timestamp
                            )

                            // Clear the event
                            prefs.edit().putBoolean("has_unread_death", false).apply()

                            Log.d(TAG, "📨 Returning stored death event: $reason")
                            result.success(deathEvent)
                        } else {
                            Log.d(TAG, "   No unread death events")
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error checking death events: ${e.message}", e)
                        result.error("CHECK_FAILED", e.message, null)
                    }
                }

                // ✅ PRIORITY 3: Check subscription status
                "checkSubscription" -> {
                    Thread {
                        try {
                            val status = runBlocking {
                                checkSubscriptionStatus()
                            }

                            Handler(Looper.getMainLooper()).post {
                                result.success(status)
                            }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("CHECK_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }

                else -> result.notImplemented()
            }
        }

        // EventChannel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STATUS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.d(TAG, "📡 EventSink CONNECTED")
                statusSink = events
            }
            override fun onCancel(arguments: Any?) {
                Log.d(TAG, "📡 EventSink DISCONNECTED")
                statusSink = null
            }
        })
    }

    // ✅ PRIORITY 3: Check subscription status
    private suspend fun checkSubscriptionStatus(): String {
        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            var sslSocket: javax.net.ssl.SSLSocket? = null

            try {
                Log.d(TAG, "🔍 Checking subscription status...")

                // Get credentials from flutter_secure_storage
                val masterKey = MasterKey.Builder(applicationContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()

                val encryptedPrefs = EncryptedSharedPreferences.create(
                    applicationContext,
                    "FlutterSecureStorage",
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )

                val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
                val accessToken = encryptedPrefs.getString("${prefix}_access_token", null)

                if (accessToken == null) {
                    Log.e(TAG, "❌ No access token found")
                    return@withContext "unknown"
                }

                Log.d(TAG, "✅ Access token found")

                // Resolve DNS (VPN is stopped, so DNS works!)
                val addresses = java.net.InetAddress.getAllByName("api.vulcainvpn.com")
                if (addresses.isEmpty()) {
                    Log.e(TAG, "❌ Could not resolve api.vulcainvpn.com")
                    return@withContext "unknown"
                }

                Log.d(TAG, "✅ DNS resolved to ${addresses[0].hostAddress}")

                // Create socket and connect
                socket = java.net.Socket()
                socket.connect(java.net.InetSocketAddress(addresses[0], 443), 5000)
                Log.d(TAG, "✅ Connected to server")

                // Wrap with SSL
                val sslFactory = javax.net.ssl.SSLSocketFactory.getDefault() as javax.net.ssl.SSLSocketFactory
                sslSocket = sslFactory.createSocket(socket, "api.vulcainvpn.com", 443, true) as javax.net.ssl.SSLSocket
                sslSocket.startHandshake()
                Log.d(TAG, "✅ SSL handshake OK")

                // Send HTTP request
                val writer = java.io.PrintWriter(java.io.OutputStreamWriter(sslSocket.outputStream))
                writer.print("GET /api/subscription HTTP/1.1\r\n")
                writer.print("Host: api.vulcainvpn.com\r\n")
                writer.print("Authorization: Bearer $accessToken\r\n")
                writer.print("Connection: close\r\n")
                writer.print("\r\n")
                writer.flush()

                // Read response
                val reader = java.io.BufferedReader(java.io.InputStreamReader(sslSocket.inputStream))
                var statusLine = ""
                var line: String?
                val body = StringBuilder()
                var readingBody = false

                while (reader.readLine().also { line = it } != null) {
                    if (statusLine.isEmpty()) statusLine = line!!
                    if (readingBody && line!!.isNotEmpty()) body.append(line)
                    if (line!!.isEmpty()) readingBody = true
                }

                val statusCode = try {
                    statusLine.split(" ")[1].toInt()
                } catch (e: Exception) {
                    0
                }

                Log.d(TAG, "📡 HTTP Response: $statusCode")

                return@withContext when {
                    statusCode == 200 -> {
                        try {
                            val json = org.json.JSONObject(body.toString())
                            val sub = json.getJSONObject("subscription")
                            val status = sub.getString("status")

                            Log.d(TAG, "✅ Subscription status: $status")

                            if (status != "active") "expired" else "active"
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ JSON parse error: ${e.message}")
                            "unknown"
                        }
                    }
                    statusCode == 401 || statusCode == 403 -> {
                        Log.d(TAG, "❌ Subscription expired (HTTP $statusCode)")
                        "expired"
                    }
                    else -> {
                        Log.w(TAG, "⚠️ Unexpected status code: $statusCode")
                        "unknown"
                    }
                }

            } catch (e: Exception) {
                Log.e(TAG, "❌ Subscription check error: ${e.message}")
                return@withContext "unknown"
            } finally {
                try { sslSocket?.close() } catch (e: Exception) {}
                try { socket?.close() } catch (e: Exception) {}
            }
        }
    }

    private fun getPackageName(result: MethodChannel.Result) {
        result.success(packageName)
    }

    private fun requestVpnPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_REQUEST_CODE
                )
                return
            }
        }
        val intent = VpnService.prepare(this)
        if (intent != null) {
            Log.d(TAG, "🔐 Requesting VPN permission from user...")
            startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            Log.d(TAG, "✅ VPN permission already granted")
            pendingResult?.let {
                startVpnInternal(it)
                pendingResult = null
                pendingConfig = null
            }
        }
    }

    private fun startVpnInternal(result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🚀 Starting VPN service...")

            val intent = Intent(this, MyVpnService::class.java).apply {
                putExtra("VPN_CONFIG", pendingConfig)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            // ✅ FIX: Add verification after starting
            Handler(mainLooper).postDelayed({
                verifyVpnStarted(result)
            }, 800) // Wait 800ms for VPN to initialize

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error starting VPN: ${e.message}", e)
            result.error("VPN_START_ERROR", e.message, null)
        }
    }

    private fun verifyVpnStarted(result: MethodChannel.Result) {
        // ✅ IMPROVED: Check actual VPN state instead of SharedPreferences
        try {
            val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = connectivityManager.activeNetwork

            if (activeNetwork != null) {
                val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                if (isVpn) {
                    Log.d(TAG, "✅ VPN verified as running (actual network check)")
                    result.success(true)
                    return
                }
            }

            // VPN not active yet, retry once
            Log.w(TAG, "⚠️ VPN not active yet, retrying in 1.5 seconds...")

            Handler(mainLooper).postDelayed({
                try {
                    val activeNetwork2 = connectivityManager.activeNetwork
                    if (activeNetwork2 != null) {
                        val caps2 = connectivityManager.getNetworkCapabilities(activeNetwork2)
                        val isVpn2 = caps2?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                        if (isVpn2) {
                            Log.d(TAG, "✅ VPN verified as running after retry (actual network check)")
                            result.success(true)
                        } else {
                            Log.e(TAG, "❌ VPN failed to start even after retry")
                            result.error(
                                "VPN_START_FAILED",
                                "VPN service did not start properly. Please try again.",
                                null
                            )
                        }
                    } else {
                        Log.e(TAG, "❌ No active network after retry")
                        result.error(
                            "VPN_START_FAILED",
                            "No network connection available.",
                            null
                        )
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error in retry check: ${e.message}", e)
                    result.error("VPN_VERIFY_ERROR", e.message, null)
                }
            }, 1500) // Wait 1.5 seconds before retry

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error verifying VPN: ${e.message}", e)
            result.error("VPN_VERIFY_ERROR", e.message, null)
        }
    }

    private fun stopVpnInternal(result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🛑 Stopping VPN service...")
            val intent = Intent(this, MyVpnService::class.java).apply {
                action = "STOP_VPN"
            }
            startService(intent)

            // Verify stopped
            Handler(mainLooper).postDelayed({
                val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                val isRunning = prefs.getBoolean("is_running", false)

                if (!isRunning) {
                    Log.d(TAG, "✅ VPN verified as stopped")
                } else {
                    Log.w(TAG, "⚠️ VPN may still be running")
                }
                result.success(true)
            }, 500)

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error stopping VPN: ${e.message}", e)
            result.error("VPN_STOP_ERROR", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == VPN_REQUEST_CODE) {
            pendingResult?.let { result ->
                if (resultCode == Activity.RESULT_OK) {
                    Log.d(TAG, "✅ VPN permission granted by user")

                    // ✅ FIX: Add delay after permission grant
                    Handler(mainLooper).postDelayed({
                        startVpnInternal(result)
                        pendingResult = null
                        pendingConfig = null
                    }, 400) // 400ms delay

                } else {
                    Log.w(TAG, "❌ User denied VPN permission")
                    result.error(
                        "VPN_PERMISSION_DENIED",
                        "User denied VPN permission",
                        null
                    )
                    pendingResult = null
                    pendingConfig = null
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == NOTIFICATION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "✅ Notification permission granted")
                requestVpnPermission()
            } else {
                Log.w(TAG, "❌ Notification permission denied")
                pendingResult?.error(
                    "NOTIFICATION_PERMISSION_DENIED",
                    "Notification permission is required",
                    null
                )
                pendingResult = null
                pendingConfig = null
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            vpnDeathReceiver?.let { unregisterReceiver(it) }
            Log.d(TAG, "✅ Unregistered VPN death broadcast receiver")
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering receiver", e)
        }
    }
}
