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
        var statusSink: EventChannel.EventSink? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ✅ Check if opened from notification
        handleNotificationIntent(intent)
    }

    // ✅ Handle notification tap when app already running
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    // ✅ Handle opening from notification
    private fun handleNotificationIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_MAIN) {
            Log.d(TAG, "📱 App opened from notification - will check for death events")

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
            }, 500)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                "updateDeathReason" -> {
                    try {
                        val reason = call.argument<String>("reason")
                        val message = call.argument<String>("message")

                        if (reason != null && message != null) {
                            val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            prefs.edit().apply {
                                putString("death_reason", reason)
                                putString("death_message", message)
                                putBoolean("has_unread_death", true)
                                apply()
                            }
                            Log.d(TAG, "✅ Updated death event to: $reason")
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "Missing reason or message", null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error updating death reason: ${e.message}", e)
                        result.error("UPDATE_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

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

    private suspend fun checkSubscriptionStatus(): String {
        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            var sslSocket: javax.net.ssl.SSLSocket? = null

            try {
                Log.d(TAG, "🔍 Checking subscription status...")

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

                val addresses = java.net.InetAddress.getAllByName("api.vulcainvpn.com")
                if (addresses.isEmpty()) {
                    Log.e(TAG, "❌ Could not resolve api.vulcainvpn.com")
                    return@withContext "unknown"
                }

                Log.d(TAG, "✅ DNS resolved to ${addresses[0].hostAddress}")

                socket = java.net.Socket()
                socket.connect(java.net.InetSocketAddress(addresses[0], 443), 5000)
                Log.d(TAG, "✅ Connected to server")

                val sslFactory = javax.net.ssl.SSLSocketFactory.getDefault() as javax.net.ssl.SSLSocketFactory
                sslSocket = sslFactory.createSocket(socket, "api.vulcainvpn.com", 443, true) as javax.net.ssl.SSLSocket
                sslSocket.startHandshake()
                Log.d(TAG, "✅ SSL handshake OK")

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

            Handler(mainLooper).postDelayed({
                verifyVpnStarted(result)
            }, 800)

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error starting VPN: ${e.message}", e)
            result.error("VPN_START_ERROR", e.message, null)
        }
    }

    private fun verifyVpnStarted(result: MethodChannel.Result) {
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
            }, 1500)

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

                    Handler(mainLooper).postDelayed({
                        startVpnInternal(result)
                        pendingResult = null
                        pendingConfig = null
                    }, 400)

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
}
