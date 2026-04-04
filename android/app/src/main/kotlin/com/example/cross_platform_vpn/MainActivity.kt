package com.example.cross_platform_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val CONTROL_CHANNEL = "com.vulcain.vpn/control"
        private const val STATUS_CHANNEL = "com.vulcain.vpn/status"

        // ✅ PRIORITY 1: Static EventSink for cross-process communication
        var statusSink: EventChannel.EventSink? = null
    }

    private var vpnDeathReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ✅ PRIORITY 1: Setup EventChannel for VPN status events
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "📡 EventChannel listener attached")
                    statusSink = events
                }

                override fun onCancel(arguments: Any?) {
                    Log.d(TAG, "📡 EventChannel listener detached")
                    statusSink = null
                }
            })

        // ✅ Setup MethodChannel for control commands
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val config = call.argument<String>("config")
                        if (config != null) {
                            startVpnService(config)
                            result.success(null)
                        } else {
                            result.error("NO_CONFIG", "VPN config is required", null)
                        }
                    }

                    "stopVpn" -> {
                        stopVpnService()
                        result.success(null)
                    }

                    "getVpnState" -> {
                        val isRunning = getVpnServiceState()
                        result.success(isRunning)
                    }

                    // ✅ PRIORITY 1: Check for stored death events (when app resumes)
                    "checkForDeathEvents" -> {
                        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                        val hasUnreadDeath = prefs.getBoolean("has_unread_death", false)

                        if (hasUnreadDeath) {
                            val deathEvent = mapOf(
                                "reason" to prefs.getString("death_reason", "unknown"),
                                "message" to prefs.getString("death_message", "VPN died unexpectedly"),
                                "timestamp" to prefs.getLong("death_timestamp", 0)
                            )

                            // Mark as read
                            prefs.edit().putBoolean("has_unread_death", false).apply()

                            result.success(deathEvent)
                        } else {
                            result.success(null)
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

        // ✅ PRIORITY 1: Register BroadcastReceiver for VPN death events
        registerVpnDeathReceiver()
    }

    // ✅ PRIORITY 1: Register receiver for cross-process communication
    private fun registerVpnDeathReceiver() {
        vpnDeathReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == "com.vulcain.vpn.VPN_DIED") {
                    val reason = intent.getStringExtra("reason") ?: "unknown"
                    val message = intent.getStringExtra("message") ?: "VPN died unexpectedly"
                    val timestamp = intent.getLongExtra("timestamp", 0)

                    Log.d(TAG, "📡 Received VPN_DIED broadcast: reason=$reason")

                    // Store in SharedPreferences (for when app is backgrounded)
                    val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    prefs.edit().apply {
                        putString("death_reason", reason)
                        putString("death_message", message)
                        putLong("death_timestamp", timestamp)
                        putBoolean("has_unread_death", true)
                        apply()
                    }

                    // Also try to send via EventSink (if app is in foreground)
                    statusSink?.success(mapOf(
                        "event" to "vpn_died",
                        "reason" to reason,
                        "message" to message,
                        "timestamp" to timestamp
                    ))
                }
            }
        }

        val filter = IntentFilter("com.vulcain.vpn.VPN_DIED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(vpnDeathReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(vpnDeathReceiver, filter)
        }

        Log.d(TAG, "✅ VPN death receiver registered")
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

    override fun onDestroy() {
        super.onDestroy()
        vpnDeathReceiver?.let {
            unregisterReceiver(it)
            Log.d(TAG, "✅ VPN death receiver unregistered")
        }
    }

    private fun startVpnService(config: String) {
        val intent = Intent(this, MyVpnService::class.java).apply {
            putExtra("VPN_CONFIG", config)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        Log.d(TAG, "✅ VPN service start requested")
    }

    private fun stopVpnService() {
        val intent = Intent(this, MyVpnService::class.java).apply {
            action = "STOP_VPN"
        }
        startService(intent)
        Log.d(TAG, "✅ VPN service stop requested")
    }

    private fun getVpnServiceState(): Boolean {
        val prefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
        return prefs.getBoolean("is_running", false)
    }
}
