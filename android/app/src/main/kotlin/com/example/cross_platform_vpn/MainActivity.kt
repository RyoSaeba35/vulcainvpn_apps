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
        @Volatile
        var statusSink: EventChannel.EventSink? = null
            private set

        fun setStatusSink(sink: EventChannel.EventSink?) {
            synchronized(this) {
                statusSink = sink
                VpnLogger.log("MainActivity", "StatusSink ${if (sink != null) "set" else "cleared"}")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        VpnLogger.init(this)
        VpnLogger.log(TAG, "🟢 MainActivity onCreate")

        handleNotificationIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        VpnLogger.log(TAG, "onNewIntent called")
        handleNotificationIntent(intent)
    }

    private fun handleNotificationIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_MAIN) {
            VpnLogger.log(TAG, "📱 App opened from notification - will check for death events")

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    val channel = flutterEngine?.dartExecutor?.binaryMessenger
                    if (channel != null) {
                        MethodChannel(channel, CONTROL_CHANNEL)
                            .invokeMethod("checkForDeathEvents", null)
                        VpnLogger.log(TAG, "✅ Triggered death event check from notification")
                    } else {
                        VpnLogger.log(TAG, "⚠️ Flutter not ready yet, death check will happen on resume")
                    }
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "Error checking death events from notification", e)
                }
            }, 500)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        VpnLogger.log(TAG, "Configuring Flutter engine")

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    VpnLogger.log(TAG, "📡 Status stream listener attached")
                    setStatusSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    VpnLogger.log(TAG, "📡 Status stream listener cancelled")
                    setStatusSink(null)
                }
            })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CONTROL_CHANNEL
        ).setMethodCallHandler { call, result ->
            VpnLogger.log(TAG, "📞 Method call: ${call.method}")

            try {
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
                        VpnLogger.log(TAG, "🚀 StartVPN called")
                        val configJson = call.argument<String>("config")

                        if (configJson == null) {
                            VpnLogger.error(TAG, "No config provided")
                            result.error("NO_CONFIG", "Config not provided", null)
                            return@setMethodCallHandler
                        }

                        pendingResult = result
                        pendingConfig = configJson

                        // Save config to encrypted storage for AutoReconnectService
                        try {
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
                            prefs.edit().putString("${prefix}_vpn_config", configJson).apply()
                            VpnLogger.log(TAG, "✅ Config saved to encrypted storage")
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to save config", e)
                        }

                        // ✅ CRITICAL FIX: Clear old death events in main process BEFORE starting VPN
                        try {
                            val vpnPrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            vpnPrefs.edit().apply {
                                remove("death_reason")
                                remove("death_message")
                                remove("death_timestamp")
                                putBoolean("has_unread_death", false)
                                apply()
                            }
                            VpnLogger.log(TAG, "✅ Cleared old death events (main process)")
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to clear old death events", e)
                        }

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
                    "stopVpn" -> {
                        VpnLogger.log(TAG, "🛑 StopVPN called")
                        stopVpnInternal(result)
                    }
                    "getStatus" -> {
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        val isRunning = prefs.getBoolean("is_running", false)
                        VpnLogger.log(TAG, "getStatus: $isRunning")
                        result.success(isRunning)
                    }
                    "getStartTime" -> {
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        val startTime = prefs.getLong("start_time", 0)
                        result.success(if (startTime > 0) startTime else null)
                    }
                    "isVpnActive" -> {
                        try {
                            val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            val activeNetwork = connectivityManager.activeNetwork

                            if (activeNetwork == null) {
                                VpnLogger.log(TAG, "isVpnActive: No active network")
                                result.success(false)
                                return@setMethodCallHandler
                            }

                            val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                            val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                            VpnLogger.log(TAG, "🔍 VPN active check: $isVpn")
                            result.success(isVpn)
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Error checking VPN active state", e)
                            result.success(false)
                        }
                    }
                    "clearVpnState" -> {
                        try {
                            val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            prefs.edit().clear().apply()
                            VpnLogger.log(TAG, "✅ Cleared stale VPN state")
                            result.success(true)
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Error clearing VPN state", e)
                            result.error("CLEAR_FAILED", e.message, null)
                        }
                    }
                    "checkForDeathEvents" -> {
                        try {
                            VpnLogger.log(TAG, "🔍 Checking for stored death events...")

                            val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            val hasUnreadDeath = prefs.getBoolean("has_unread_death", false)

                            VpnLogger.log(TAG, "   has_unread_death: $hasUnreadDeath")

                            if (hasUnreadDeath) {
                                val reason = prefs.getString("death_reason", "unknown")
                                val message = prefs.getString("death_message", "VPN died unexpectedly")
                                val timestamp = prefs.getLong("death_timestamp", 0)

                                VpnLogger.log(TAG, "   reason: $reason")
                                VpnLogger.log(TAG, "   message: $message")

                                val deathEvent = mapOf(
                                    "reason" to reason,
                                    "message" to message,
                                    "timestamp" to timestamp
                                )

                                prefs.edit().putBoolean("has_unread_death", false).apply()

                                VpnLogger.log(TAG, "📨 Returning stored death event: $reason")
                                result.success(deathEvent)
                            } else {
                                VpnLogger.log(TAG, "   No unread death events")
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Error checking death events", e)
                            result.error("CHECK_FAILED", e.message, null)
                        }
                    }
                    "checkSubscription" -> {
                        VpnLogger.log(TAG, "Checking subscription...")
                        Thread {
                            try {
                                val status = runBlocking { checkSubscriptionStatus() }
                                VpnLogger.log(TAG, "Subscription status: $status")
                                Handler(Looper.getMainLooper()).post {
                                    result.success(status)
                                }
                            } catch (e: Exception) {
                                VpnLogger.error(TAG, "Subscription check failed", e)
                                Handler(Looper.getMainLooper()).post {
                                    result.success("unknown")
                                }
                            }
                        }.start()
                    }
                    "updateDeathReason" -> {
                        try {
                            val reason = call.argument<String>("reason")
                            val message = call.argument<String>("message")

                            VpnLogger.log(TAG, "📝 Updating death reason: $reason")

                            val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            prefs.edit().apply {
                                putString("death_reason", reason)
                                putString("death_message", message)
                                putLong("death_timestamp", System.currentTimeMillis())
                                putBoolean("has_unread_death", true)
                                apply()
                            }

                            VpnLogger.log(TAG, "✅ Death reason updated to: $reason")
                            result.success(true)
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to update death reason", e)
                            result.error("UPDATE_FAILED", e.message, null)
                        }
                    }
                    "clearDeathEvents" -> {
                        VpnLogger.log(TAG, "🗑️ Clearing stored death events")
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        prefs.edit().putBoolean("has_unread_death", false).apply()
                        result.success(null)
                    }
                    else -> {
                        VpnLogger.log(TAG, "⚠️ Unknown method: ${call.method}")
                        result.notImplemented()
                    }
                }
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Method call handler error for ${call.method}", e)
                result.error("HANDLER_ERROR", e.message, null)
            }
        }
    }

    private suspend fun checkSubscriptionStatus(): String {
        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            var sslSocket: javax.net.ssl.SSLSocket? = null

            try {
                val accessToken = getSecureValue("access_token") ?: return@withContext "unknown"

                val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val underlyingNetwork = connectivityManager.allNetworks.firstOrNull { network ->
                    val caps = connectivityManager.getNetworkCapabilities(network)
                    caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))
                } ?: return@withContext "unknown"

                val ipAddress = try {
                    val originalNetwork = connectivityManager.boundNetworkForProcess
                    try {
                        connectivityManager.bindProcessToNetwork(underlyingNetwork)
                        val addresses = java.net.InetAddress.getAllByName("api.vulcainvpn.com")
                        if (addresses.isEmpty()) throw Exception("No addresses resolved")
                        addresses[0]
                    } finally {
                        connectivityManager.bindProcessToNetwork(originalNetwork)
                    }
                } catch (e: Exception) {
                    return@withContext "unknown"
                }

                socket = java.net.Socket()
                val protected = (application as? VpnApplication)?.let { false } ?: false

                if (!protected) {
                    try {
                        underlyingNetwork.bindSocket(socket)
                    } catch (e: Exception) {}
                }

                socket.connect(java.net.InetSocketAddress(ipAddress, 443), 5000)

                val sslFactory = javax.net.ssl.SSLSocketFactory.getDefault() as javax.net.ssl.SSLSocketFactory
                sslSocket = sslFactory.createSocket(socket, "api.vulcainvpn.com", 443, true) as javax.net.ssl.SSLSocket
                sslSocket.startHandshake()

                val writer = java.io.PrintWriter(java.io.OutputStreamWriter(sslSocket.outputStream))
                writer.print("GET /api/subscription HTTP/1.1\r\n")
                writer.print("Host: api.vulcainvpn.com\r\n")
                writer.print("Authorization: Bearer $accessToken\r\n")
                writer.print("Connection: close\r\n")
                writer.print("\r\n")
                writer.flush()

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

                return@withContext when {
                    statusCode == 200 -> {
                        try {
                            val json = org.json.JSONObject(body.toString())
                            val sub = json.getJSONObject("subscription")
                            val status = sub.getString("status")
                            if (status != "active") "expired" else "active"
                        } catch (e: Exception) {
                            "unknown"
                        }
                    }
                    statusCode == 401 || statusCode == 403 -> "expired"
                    else -> "unknown"
                }

            } catch (e: Exception) {
                VpnLogger.error(TAG, "Subscription check error", e)
                return@withContext "unknown"
            } finally {
                try { sslSocket?.close() } catch (e: Exception) {}
                try { socket?.close() } catch (e: Exception) {}
            }
        }
    }

    private fun getSecureValue(key: String): String? {
        return try {
            val masterKey = MasterKey.Builder(applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            val encryptedPrefs = EncryptedSharedPreferences.create(
                applicationContext,
                "FlutterSecureStorage",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)

            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            val fullKey = "${prefix}_${key}"
            encryptedPrefs.getString(fullKey, null)
        } catch (e: Exception) {
            null
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
            VpnLogger.log(TAG, "🔐 Requesting VPN permission from user...")
            startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            VpnLogger.log(TAG, "✅ VPN permission already granted")
            pendingResult?.let {
                startVpnInternal(it)
                pendingResult = null
                pendingConfig = null
            }
        }
    }

    private fun startVpnInternal(result: MethodChannel.Result) {
        try {
            VpnLogger.log(TAG, "🚀 Starting VPN service...")

            val intent = Intent(this, MyVpnService::class.java).apply {
                putExtra("VPN_CONFIG", pendingConfig)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            // ✅ FIXED: Start verification with better retry logic
            verifyVpnStarted(result, 0)

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error starting VPN", e)
            result.error("VPN_START_ERROR", e.message, null)
        }
    }

    /**
     * ✅ FIXED: Recursive verification with up to 6 seconds total wait time
     * Checks: 800ms, 2.3s, 3.8s, 5.3s, 6.8s
     */
    private fun verifyVpnStarted(result: MethodChannel.Result, attemptNumber: Int) {
        val delays = listOf(800L, 1500L, 1500L, 1500L, 1500L)  // Total: 6.8 seconds max

        if (attemptNumber >= delays.size) {
            VpnLogger.error(TAG, "❌ VPN failed to start after ${delays.size} attempts (${delays.sum()}ms)")
            result.error(
                "VPN_START_FAILED",
                "VPN service did not start properly. Please try again.",
                null
            )
            return
        }

        Handler(mainLooper).postDelayed({
            try {
                val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val activeNetwork = connectivityManager.activeNetwork

                if (activeNetwork != null) {
                    val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                    val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                    if (isVpn) {
                        VpnLogger.log(TAG, "✅ VPN verified as running (attempt ${attemptNumber + 1}/${delays.size})")
                        result.success(true)
                        return@postDelayed
                    }
                }

                VpnLogger.log(TAG, "⏳ VPN not ready yet, retry ${attemptNumber + 1}/${delays.size}...")

                // Recursive call for next attempt
                verifyVpnStarted(result, attemptNumber + 1)

            } catch (e: Exception) {
                VpnLogger.error(TAG, "Error in verification attempt ${attemptNumber + 1}", e)
                verifyVpnStarted(result, attemptNumber + 1)
            }
        }, delays[attemptNumber])
    }

    private fun stopVpnInternal(result: MethodChannel.Result) {
        try {
            VpnLogger.log(TAG, "🛑 Stopping VPN service...")
            val intent = Intent(this, MyVpnService::class.java).apply {
                action = "STOP_VPN"
            }
            startService(intent)

            Handler(mainLooper).postDelayed({
                val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                val isRunning = prefs.getBoolean("is_running", false)

                if (!isRunning) {
                    VpnLogger.log(TAG, "✅ VPN verified as stopped")
                } else {
                    VpnLogger.log(TAG, "⚠️ VPN may still be running")
                }
                result.success(true)
            }, 500)

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error stopping VPN", e)
            result.error("VPN_STOP_ERROR", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == VPN_REQUEST_CODE) {
            pendingResult?.let { result ->
                if (resultCode == Activity.RESULT_OK) {
                    VpnLogger.log(TAG, "✅ VPN permission granted by user")

                    Handler(mainLooper).postDelayed({
                        startVpnInternal(result)
                        pendingResult = null
                        pendingConfig = null
                    }, 400)

                } else {
                    VpnLogger.log(TAG, "❌ User denied VPN permission")
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
                VpnLogger.log(TAG, "✅ Notification permission granted")
                requestVpnPermission()
            } else {
                VpnLogger.log(TAG, "❌ Notification permission denied")
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
        VpnLogger.log(TAG, "🔴 MainActivity destroyed")
        setStatusSink(null)
    }
}
