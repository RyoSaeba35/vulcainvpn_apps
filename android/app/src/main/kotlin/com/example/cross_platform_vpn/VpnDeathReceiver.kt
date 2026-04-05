package com.example.cross_platform_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.app.NotificationManager
import kotlinx.coroutines.*
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class VpnDeathReceiver : BroadcastReceiver() {

    private val TAG = "VpnDeathReceiver"

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.vulcain.vpn.VPN_DIED") return

        val reason = intent.getStringExtra("reason") ?: "unknown"
        val message = intent.getStringExtra("message") ?: "VPN died"
        val timestamp = intent.getLongExtra("timestamp", 0)

        Log.d(TAG, "📻 Received VPN_DIED broadcast: $reason (app in background)")

        // Store death event
        try {
            val prefs = context.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
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

        // Try to send via EventSink (if Flutter is running)
        if (MainActivity.statusSink != null) {
            MainActivity.statusSink?.success(mapOf(
                "event" to "vpn_died",
                "reason" to reason,
                "message" to message,
                "timestamp" to timestamp
            ))
            Log.d(TAG, "   ✅ Sent to Flutter via EventSink")
        } else {
            Log.d(TAG, "   ⚠️ Flutter not running, stored for later")
        }

        // Check if auto-reconnect is enabled
        val settingsPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val autoReconnectKey = "flutter.auto_reconnect_enabled"
        val autoReconnectEnabled = settingsPrefs.getBoolean(autoReconnectKey, true)

        Log.d(TAG, "   🔄 Auto-reconnect enabled: $autoReconnectEnabled")

        // Check if reason is reconnectable
        val isReconnectable = when (reason) {
            "service_killed" -> true
            "process_crashed" -> true
            "vpn_broken" -> true
            "subscription_expired" -> true
            "permission_revoked" -> false
            else -> false
        }

        Log.d(TAG, "   🔄 Reason reconnectable: $isReconnectable")

        // Start auto-reconnect in background
        if (autoReconnectEnabled && isReconnectable) {
            Log.d(TAG, "   🔄 Starting background auto-reconnect...")
            startBackgroundAutoReconnect(context, reason, message)
        } else {
            Log.d(TAG, "   ⏸️ Skipping auto-reconnect (disabled or not reconnectable)")

            // Just show notification
            showReconnectNotification(
                context,
                when (reason) {
                    "permission_revoked" -> "VPN Permission Revoked"
                    "service_killed" -> "VPN Service Stopped"
                    "process_crashed" -> "VPN Crashed"
                    "vpn_broken" -> "VPN Connection Lost"
                    "subscription_expired" -> "Subscription Expired"
                    else -> "VPN Disconnected"
                },
                when (reason) {
                    "permission_revoked" -> "Please re-enable VPN permission"
                    "subscription_expired" -> "Your VPN subscription has expired. Tap to renew."
                    else -> "Tap to reconnect"
                }
            )
        }
    }

    private fun startBackgroundAutoReconnect(context: Context, reason: String, message: String) {
        // Use goAsync() to keep receiver alive during async work
        val pendingResult = goAsync()

        Thread {
            try {
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
                            checkSubscriptionStatus(context)
                        }

                        if (subscriptionStatus == "expired") {
                            Log.d(TAG, "   🔴 Subscription expired - stopping auto-reconnect")

                            // Update stored event
                            val prefs = context.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            prefs.edit().apply {
                                putString("death_reason", "subscription_expired")
                                putString("death_message", "Your VPN subscription has expired")
                                putBoolean("has_unread_death", true)
                                apply()
                            }

                            // Show notification
                            showReconnectNotification(
                                context,
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

                        // Step 2: Get VPN config
                        val masterKey = MasterKey.Builder(context)
                            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                            .build()

                        val encryptedPrefs = EncryptedSharedPreferences.create(
                            context,
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
                        val vpnIntent = Intent(context, MyVpnService::class.java).apply {
                            putExtra("VPN_CONFIG", vpnConfig)
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(vpnIntent)
                        } else {
                            context.startService(vpnIntent)
                        }

                        Log.d(TAG, "   🚀 VPN service start requested")

                        // Wait for VPN to start
                        Thread.sleep(2000)

                        // Step 4: Verify VPN started
                        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val activeNetwork = connectivityManager.activeNetwork
                        val caps = activeNetwork?.let {
                            connectivityManager.getNetworkCapabilities(it)
                        }
                        val isVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true

                        if (isVpn) {
                            Log.d(TAG, "   ✅ Auto-reconnect SUCCESS on attempt $attempt")

                            // Clear death event
                            val prefs = context.getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                            prefs.edit().apply {
                                putBoolean("has_unread_death", false)
                                apply()
                            }

                            // Cancel notifications
                            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            notificationManager.cancel(1001)

                            // Notify Flutter if running
                            if (MainActivity.statusSink != null) {
                                Handler(Looper.getMainLooper()).post {
                                    MainActivity.statusSink?.success(mapOf(
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

                // All attempts failed
                Log.d(TAG, "🔴 Auto-reconnect FAILED after $maxAttempts attempts")

                showReconnectNotification(
                    context,
                    when (reason) {
                        "service_killed" -> "VPN Service Stopped"
                        "process_crashed" -> "VPN Crashed"
                        "vpn_broken" -> "VPN Connection Lost"
                        else -> "VPN Disconnected"
                    },
                    "Could not reconnect automatically. Tap to try again."
                )

            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    private fun showReconnectNotification(context: Context, title: String, message: String) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Create notification channel
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
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = android.app.PendingIntent.getActivity(
                context,
                0,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.app.Notification.Builder(context, "vpn_status")
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(context)
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

    private suspend fun checkSubscriptionStatus(context: Context): String {
        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            var sslSocket: javax.net.ssl.SSLSocket? = null

            try {
                Log.d(TAG, "🔍 Checking subscription status...")

                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()

                val encryptedPrefs = EncryptedSharedPreferences.create(
                    context,
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

                val addresses = java.net.InetAddress.getAllByName("api.vulcainvpn.com")
                if (addresses.isEmpty()) {
                    Log.e(TAG, "❌ Could not resolve api.vulcainvpn.com")
                    return@withContext "unknown"
                }

                socket = java.net.Socket()
                socket.connect(java.net.InetSocketAddress(addresses[0], 443), 5000)

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
                Log.e(TAG, "❌ Subscription check error: ${e.message}")
                return@withContext "unknown"
            } finally {
                try { sslSocket?.close() } catch (e: Exception) {}
                try { socket?.close() } catch (e: Exception) {}
            }
        }
    }
}
