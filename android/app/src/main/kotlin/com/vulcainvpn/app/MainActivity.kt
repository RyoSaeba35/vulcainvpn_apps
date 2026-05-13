package com.vulcainvpn.app

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
// ✅ Battery optimization imports
import android.os.PowerManager
import android.net.Uri
import android.provider.Settings
import androidx.work.*
import java.util.concurrent.TimeUnit
import android.app.NotificationChannel
import android.app.PendingIntent
import androidx.core.app.NotificationCompat

class MainActivity : FlutterActivity() {

    private val CONTROL_CHANNEL = "com.vulcain.vpn/control"
    private val STATUS_CHANNEL = "com.vulcain.vpn/status"

    private val VPN_REQUEST_CODE = 1001
    private val NOTIFICATION_REQUEST_CODE = 1002
    private val BATTERY_OPTIMIZATION_REQUEST_CODE = 1003
    private val TAG = "MainActivity"

    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var pendingAccessToken: String? = null

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

        handleAppUpdateRecovery()

        VpnLogger.init(this)
        VpnLogger.log(TAG, "🟢 MainActivity onCreate")

        scheduleVpnHealthChecks()
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
                    "checkBatteryOptimization" -> {
                        result.success(isBatteryOptimizationExempt())
                    }
                    "requestBatteryOptimization" -> {
                        requestBatteryOptimizationExemption()
                        result.success(null)
                    }
                    "getPackageName" -> getPackageName(result)
                    "startVpn" -> {
                        VpnLogger.log(TAG, "🚀 StartVPN called")
                        val configJson = call.argument<String>("config")
                        val accessToken = call.argument<String>("access_token")

                        if (configJson == null) {
                            VpnLogger.error(TAG, "No config provided")
                            result.error("NO_CONFIG", "Config not provided", null)
                            return@setMethodCallHandler
                        }

                        if (accessToken == null) {
                            VpnLogger.error(TAG, "No access token provided")
                            result.error("NO_TOKEN", "Access token required", null)
                            return@setMethodCallHandler
                        }

                        pendingResult = result
                        pendingConfig = configJson
                        pendingAccessToken = accessToken

                        // Save config and token to encrypted storage for AutoReconnectService
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
                            prefs.edit().apply {
                                putString("${prefix}_vpn_config", configJson)
                                putString("${prefix}_access_token", accessToken)
                                apply()
                            }
                            VpnLogger.log(TAG, "✅ Config and token saved to encrypted storage")
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to save config/token", e)
                        }

                        // Clear old death events BEFORE starting VPN
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

                        // ✅ RESET AUTO-RECONNECT COUNTER ON MANUAL CONNECT
                        try {
                            val retryPrefs = getSharedPreferences("auto_reconnect_retry", Context.MODE_PRIVATE)
                            retryPrefs.edit().apply {
                                putInt("retry_count", 0)
                                putInt("retry_batch", 1)
                                putLong("last_retry_time", 0)
                                apply()
                            }
                            VpnLogger.log(TAG, "✅ Reset auto-reconnect counter (manual connect)")
                        } catch (e: Exception) {
                            VpnLogger.error(TAG, "Failed to reset retry counter", e)
                        }

                        // ✅ STEP 1: Battery optimization check (MANDATORY)
                        if (!isBatteryOptimizationExempt()) {
                            VpnLogger.log(TAG, "⚠️ Battery optimization not exempt - requesting")
                            requestBatteryOptimizationExemption()
                            return@setMethodCallHandler
                        } else {
                            VpnLogger.log(TAG, "✅ Battery optimization already exempt")
                        }

                        // ✅ STEP 2: Notification permission (if needed)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    NOTIFICATION_REQUEST_CODE
                                )
                                return@setMethodCallHandler
                            }
                        }

                        // ✅ STEP 3: VPN permission
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

    private fun isBatteryOptimizationExempt(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val isExempt = pm.isIgnoringBatteryOptimizations(packageName)
            return isExempt
        }
        return true
    }

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val intent = Intent().apply {
                    action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                    data = Uri.parse("package:$packageName")
                }
                startActivityForResult(intent, BATTERY_OPTIMIZATION_REQUEST_CODE)
                VpnLogger.log(TAG, "✅ Battery optimization exemption requested")
            } catch (e: Exception) {
                VpnLogger.error(TAG, "Failed to request battery exemption", e)
                // If we can't request it, fail the connection
                pendingResult?.error(
                    "BATTERY_OPTIMIZATION_FAILED",
                    "Battery optimization setting could not be accessed. This is required for VPN to work properly.",
                    null
                )
                pendingResult = null
                pendingConfig = null
                pendingAccessToken = null
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
                    statusCode == 401 || statusCode == 403 -> "auth_failed"
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
                pendingAccessToken = null
            }
        }
    }

    private fun startVpnInternal(result: MethodChannel.Result) {
        try {
            VpnLogger.log(TAG, "🚀 Starting VPN service...")

            val intent = Intent(this, MyVpnService::class.java).apply {
                putExtra("VPN_CONFIG", pendingConfig)
                putExtra("ACCESS_TOKEN", pendingAccessToken)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            verifyVpnStarted(result, 0)

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error starting VPN", e)
            result.error("VPN_START_ERROR", e.message, null)
        }
    }

    private fun verifyVpnStarted(result: MethodChannel.Result, attemptNumber: Int) {
        val delays = listOf(800L, 1500L, 1500L, 1500L, 1500L)

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

        when (requestCode) {
            VPN_REQUEST_CODE -> {
                pendingResult?.let { result ->
                    if (resultCode == Activity.RESULT_OK) {
                        VpnLogger.log(TAG, "✅ VPN permission granted by user")

                        Handler(mainLooper).postDelayed({
                            startVpnInternal(result)
                            pendingResult = null
                            pendingConfig = null
                            pendingAccessToken = null
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
                        pendingAccessToken = null
                    }
                }
            }
            BATTERY_OPTIMIZATION_REQUEST_CODE -> {
                // ✅ Check if battery optimization was granted (MANDATORY)
                val isExempt = isBatteryOptimizationExempt()

                if (isExempt) {
                    VpnLogger.log(TAG, "✅ Battery optimization exemption granted")

                    // ✅ Continue to notification permission
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            VpnLogger.log(TAG, "⚠️ Notification permission needed - requesting")
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                NOTIFICATION_REQUEST_CODE
                            )
                            return
                        }
                    }

                    // If notification permission already granted (or not needed), proceed to VPN permission
                    VpnLogger.log(TAG, "✅ Notification permission already granted or not needed")
                    requestVpnPermission()

                } else {
                    // ✅ Battery optimization DENIED - stop connection (like VPN/notification denial)
                    VpnLogger.log(TAG, "❌ Battery optimization NOT granted - connection blocked")
                    pendingResult?.error(
                        "BATTERY_OPTIMIZATION_DENIED",
                        "Battery optimization exemption is required for VPN to work properly in the background. Without it, Android may kill your VPN connection.",
                        null
                    )
                    pendingResult = null
                    pendingConfig = null
                    pendingAccessToken = null
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
                pendingAccessToken = null
            }
        }
    }

    // ✅ NEW: Schedule periodic VPN health checks via WorkManager
    private fun scheduleVpnHealthChecks() {
        try {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.NOT_REQUIRED)  // Run even without network
                .setRequiresBatteryNotLow(false)  // Run even on low battery
                .setRequiresCharging(false)  // Run when not charging
                .build()

            val healthCheckRequest = PeriodicWorkRequestBuilder<VpnHealthCheckWorker>(
                15, TimeUnit.MINUTES  // Every 15 minutes (minimum allowed)
            )
                .setConstraints(constraints)
                .setBackoffCriteria(
                    BackoffPolicy.LINEAR,
                    1, TimeUnit.MINUTES
                )
                .build()

            WorkManager.getInstance(this).enqueueUniquePeriodicWork(
                "vpn_health_check",
                ExistingPeriodicWorkPolicy.KEEP,  // Keep existing if already scheduled
                healthCheckRequest
            )

            Log.d(TAG, "✅ WorkManager VPN health checks scheduled (every 15 min)")
            VpnLogger.log(TAG, "✅ WorkManager VPN health checks scheduled")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule WorkManager: ${e.message}")
            VpnLogger.error(TAG, "Failed to schedule WorkManager", e)
        }
    }

    private fun handleAppUpdateRecovery() {
        try {
            val appPrefs = getSharedPreferences("app_state", Context.MODE_PRIVATE)
            val vpnPrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)

            val lastVersion = appPrefs.getInt("version_code", 0)
            val currentVersion = packageManager.getPackageInfo(packageName, 0).longVersionCode.toInt()

            val wasRunning = vpnPrefs.getBoolean("vpn_running", false)

            // First launch or same version - no update
            if (lastVersion == 0 || lastVersion == currentVersion) {
                appPrefs.edit().putInt("version_code", currentVersion).apply()
                return
            }

            VpnLogger.log(TAG, "📦 App updated: v$lastVersion → v$currentVersion")

            if (wasRunning) {
                VpnLogger.log(TAG, "⚠️ VPN was running during update - initiating recovery")

                // CRITICAL: Aggressive cleanup
                performAppUpdateRecovery()

                // Store death event
                vpnPrefs.edit()
                    .putBoolean("has_unread_death", true)
                    .putString("death_reason", "app_updated")
                    .putString("death_message", "App updated - reconnect to continue")
                    .putBoolean("vpn_running", false)
                    .putBoolean("auto_reconnect_enabled", false) // Don't auto-reconnect!
                    .apply()

                // Show user-friendly notification
                showAppUpdateNotification()
            }

            // Update version
            appPrefs.edit().putInt("version_code", currentVersion).apply()

        } catch (e: Exception) {
            VpnLogger.error(TAG, "App update recovery failed", e)
        }
    }

    private fun performAppUpdateRecovery() {
        VpnLogger.log(TAG, "🧹 Starting app update recovery cleanup...")

        try {
            // 1. Stop all services aggressively
            VpnLogger.log(TAG, "Stopping MyVpnService...")
            stopService(Intent(this, MyVpnService::class.java))

            VpnLogger.log(TAG, "Stopping VpnWatchdogService...")
            stopService(Intent(this, VpnWatchdogService::class.java))

            VpnLogger.log(TAG, "Stopping AutoReconnectService...")
            stopService(Intent(this, AutoReconnectService::class.java))

            // Give Android time to actually stop services
            Thread.sleep(500)

            // 2. Clear all VPN-related shared preferences
            VpnLogger.log(TAG, "Clearing VPN state...")
            getSharedPreferences("vpn_state", Context.MODE_PRIVATE).edit().clear().apply()

            VpnLogger.log(TAG, "Clearing auto-reconnect state...")
            getSharedPreferences("auto_reconnect_retry", Context.MODE_PRIVATE).edit().clear().apply()

            // 3. Cancel all notifications
            VpnLogger.log(TAG, "Clearing notifications...")
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.cancelAll()

            // 4. Cancel WorkManager jobs
            VpnLogger.log(TAG, "Canceling WorkManager jobs...")
            WorkManager.getInstance(this).cancelAllWork()

            // 5. Re-schedule WorkManager (fresh start)
            VpnLogger.log(TAG, "Re-scheduling WorkManager...")
            scheduleVpnHealthChecks() // Your existing method

            VpnLogger.log(TAG, "✅ App update recovery complete")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Recovery cleanup error", e)
        }
    }

    private fun showAppUpdateNotification() {
        try {
            val notificationManager = getSystemService(NotificationManager::class.java)

            // Create channel if needed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    "app_updates",
                    "App Updates",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Important app update notifications"
                    enableVibration(true)
                    setShowBadge(true)
                }
                notificationManager.createNotificationChannel(channel)
            }

            // Intent to open app and trigger reconnect
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("app_updated_reconnect", true)
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, "app_updates")
                .setContentTitle("VulcainVPN Updated")
                .setContentText("Tap to reconnect VPN")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .build()

            notificationManager.notify(9999, notification)

            VpnLogger.log(TAG, "✅ App update notification shown")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to show app update notification", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        VpnLogger.log(TAG, "🔴 MainActivity destroyed")
        setStatusSink(null)
    }

}
