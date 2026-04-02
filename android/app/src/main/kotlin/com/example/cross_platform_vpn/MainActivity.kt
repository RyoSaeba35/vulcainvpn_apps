package com.example.cross_platform_vpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Handler
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.content.Context
import android.app.NotificationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

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
                else -> result.notImplemented()
            }
        }

        // EventChannel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STATUS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusSink = events
            }
            override fun onCancel(arguments: Any?) {
                statusSink = null
            }
        })
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
        // SharedPreferences doesn't sync instantly across processes!
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
                    // This ensures Android fully processes the permission
                    Handler(mainLooper).postDelayed({
                        startVpnInternal(result)
                        pendingResult = null
                        pendingConfig = null
                    }, 400) // 400ms delay instead of immediate Handler.post

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
