package com.vulcainvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import android.net.ConnectivityManager
import android.content.Context.CONNECTIVITY_SERVICE
import android.net.NetworkCapabilities
import android.system.OsConstants
import java.net.Inet6Address
import java.net.NetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.PlatformInterface
import kotlinx.coroutines.runBlocking
import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.*
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import android.net.Network
import android.net.NetworkRequest
import android.os.PowerManager
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import android.content.ComponentName

class MyVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "MyVpnService"
        private const val NOTIFICATION_ID = VpnConstants.SHARED_NOTIFICATION_ID
        private const val CHANNEL_ID = VpnConstants.NOTIFICATION_CHANNEL_ID

        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val KEY_START_TIME = "start_time"
        private const val KEY_LAST_SEEN_AT = "last_seen_at"

        // ✅ IMPROVED: More reliable heartbeat timing
        private const val HEARTBEAT_INTERVAL_MS = 10000L  // 10s
        private const val HEARTBEAT_TIMEOUT_MS = 5000  // 5s (was 3s) - more tolerance
        private const val MAX_CONSECUTIVE_FAILURES = 4  // 40s total (was 3) - more tolerance

        // ✅ NEW: Wake lock constants
        private const val WAKE_LOCK_TIMEOUT_MS = 30000L  // 30 seconds

        // ✅ NEW: Prevent concurrent VPN starts
        @Volatile
        private var isStarting = false
    }

    private var commandServer: CommandServer? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var cachedInterfaces: List<LibboxNetworkInterface>? = null
    private var cachedConfig: String? = null
    private var cachedAccessToken: String? = null

    private var isNormalStop = false
    private var deathEventSent = false

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var heartbeatJob: Job? = null

    private var consecutiveFailures = 0
    private var lastSuccessfulPing: Long = 0
    private var heartbeatCounter = 0  // ✅ NEW: Counter for periodic subscription checks

    private val isServiceAlive = AtomicBoolean(true)

    // ✅ NEW: 403 error detection variables
    private val auth403Count = AtomicInteger(0)
    private val last403Time = AtomicLong(0L)
    private val auth403Lock = Any()  // Synchronization lock
    private val AUTH_403_THRESHOLD = 5
    private val AUTH_403_WINDOW_MS = 30000L  // 30 seconds
    private val isHandlingSubscriptionExpired = AtomicBoolean(false)

    // ✅ NEW: VPN network callback for instant detection
    private var vpnNetworkCallback: ConnectivityManager.NetworkCallback? = null

    // ✅ NEW: Wake lock variable
    private var wakeLock: PowerManager.WakeLock? = null

    // ✅ NEW: Airplane mode broadcast receiver
    private var airplaneModeReceiver: BroadcastReceiver? = null

    private val prefsLock = Any()
    private val prefs: SharedPreferences by lazy {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")
        isServiceAlive.set(true)
        deathEventSent = false
        createNotificationChannel()

        // ✅ NEW: Set higher process priority
        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_FOREGROUND)
            VpnLogger.log(TAG, "✅ Process priority set to FOREGROUND")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to set process priority", e)
        }

        // ✅ NEW: Initialize wake lock
        initializeWakeLock()

        // ✅ NEW: Register VPN death monitor
        registerVpnDeathMonitor()

        // ✅ NEW: Register airplane mode monitor
        registerAirplaneModeReceiver()
    }

    // ✅ NEW: Initialize wake lock
    private fun initializeWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "VulcainVPN::ServiceWakeLock"
            )
            wakeLock?.setReferenceCounted(false)
            VpnLogger.log(TAG, "✅ Wake lock initialized")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to initialize wake lock", e)
        }
    }

    // ✅ NEW: Acquire wake lock with timeout
    private fun acquireWakeLock(reason: String) {
        try {
            wakeLock?.let { lock ->
                if (!lock.isHeld) {
                    lock.acquire(WAKE_LOCK_TIMEOUT_MS)
                    VpnLogger.log(TAG, "🔒 Wake lock acquired ($reason)")
                    Log.d(TAG, "🔒 Wake lock acquired: $reason")
                }
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to acquire wake lock", e)
        }
    }

    // ✅ NEW: Release wake lock
    private fun releaseWakeLock(reason: String) {
        try {
            wakeLock?.let { lock ->
                if (lock.isHeld) {
                    lock.release()
                    VpnLogger.log(TAG, "🔓 Wake lock released ($reason)")
                    Log.d(TAG, "🔓 Wake lock released: $reason")
                }
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to release wake lock", e)
        }
    }

    // ✅ NEW: Smart network detection helper
    private fun hasUnderlyingNetwork(): Boolean {
        return try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false

            // Check for non-VPN transport types
            val hasWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            val hasCellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            val hasEthernet = caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

            val result = hasWifi || hasCellular || hasEthernet

            VpnLogger.log(TAG, "📶 Network check: WiFi=$hasWifi, Cellular=$hasCellular, Ethernet=$hasEthernet → $result")

            result
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Network check error", e)
            false
        }
    }

    // ✅ NEW: Register VPN network callback for instant death detection
    private fun registerVpnDeathMonitor() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

            val vpnRequest = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                .build()

            vpnNetworkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    VpnLogger.log(TAG, "🟢 VPN network available: $network")
                    Log.d(TAG, "🟢 VPN network available: $network")
                }

                override fun onLost(network: Network) {
                    VpnLogger.critical(TAG, "🚨 VPN NETWORK LOST (Layer 1 instant detection): $network")
                    Log.e(TAG, "🚨 VPN NETWORK LOST - Network callback detected VPN death! Network: $network")

                    // Only trigger if we think VPN is still running
                    if (getVpnState() && !deathEventSent) {
                        Log.e(TAG, "🔴 VPN was running, triggering instant death handler")
                        mainHandler.post {
                            handleVpnNetworkLost()
                        }
                    } else {
                        Log.w(TAG, "⚠️ VPN already stopped or death already sent - ignoring callback")
                    }
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    val isValidated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    if (!isValidated) {
                        VpnLogger.log(TAG, "⚠️ VPN network not validated")
                        Log.w(TAG, "⚠️ VPN network not validated")
                    }
                }
            }

            cm.registerNetworkCallback(vpnRequest, vpnNetworkCallback!!)
            VpnLogger.log(TAG, "✅ VPN death monitor registered")
            Log.d(TAG, "✅ VPN network callback registered (Layer 1 instant detection)")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to register VPN death monitor", e)
            Log.e(TAG, "Failed to register VPN network callback: ${e.message}")
        }
    }

    // ✅ NEW: Unregister VPN network callback
    private fun unregisterVpnDeathMonitor() {
        try {
            vpnNetworkCallback?.let {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                cm.unregisterNetworkCallback(it)
                VpnLogger.log(TAG, "✅ VPN death monitor unregistered")
                Log.d(TAG, "✅ VPN network callback unregistered")
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to unregister VPN death monitor", e)
            Log.e(TAG, "Failed to unregister VPN network callback: ${e.message}")
        }
        vpnNetworkCallback = null
    }

    // ✅ NEW: Register airplane mode broadcast receiver for instant detection
    private fun registerAirplaneModeReceiver() {
        try {
            airplaneModeReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == Intent.ACTION_AIRPLANE_MODE_CHANGED) {
                        val isAirplaneModeOn = intent.getBooleanExtra("state", false)

                        VpnLogger.log(TAG, "✈️ Airplane mode changed: $isAirplaneModeOn")
                        Log.d(TAG, "✈️ Airplane mode broadcast received: $isAirplaneModeOn")

                        if (isAirplaneModeOn && getVpnState() && !deathEventSent) {
                            Log.e(TAG, "🚨 AIRPLANE MODE ENABLED - Stopping VPN immediately")
                            VpnLogger.critical(TAG, "🚨 AIRPLANE MODE ENABLED - Immediate VPN shutdown")

                            mainHandler.post {
                                handleAirplaneModeEnabled()
                            }
                        }
                    }
                }
            }

            val filter = IntentFilter(Intent.ACTION_AIRPLANE_MODE_CHANGED)
            registerReceiver(airplaneModeReceiver, filter)

            VpnLogger.log(TAG, "✅ Airplane mode monitor registered")
            Log.d(TAG, "✅ Airplane mode broadcast receiver registered")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to register airplane mode monitor", e)
            Log.e(TAG, "Failed to register airplane mode receiver: ${e.message}")
        }
    }

    // ✅ NEW: Unregister airplane mode broadcast receiver
    private fun unregisterAirplaneModeReceiver() {
        try {
            airplaneModeReceiver?.let {
                unregisterReceiver(it)
                VpnLogger.log(TAG, "✅ Airplane mode monitor unregistered")
                Log.d(TAG, "✅ Airplane mode broadcast receiver unregistered")
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to unregister airplane mode monitor", e)
            Log.e(TAG, "Failed to unregister airplane mode receiver: ${e.message}")
        }
        airplaneModeReceiver = null
    }

    // ✅ NEW: Handle airplane mode enabled (instant shutdown)
    private fun handleAirplaneModeEnabled() {
        if (!isServiceAlive.get() || deathEventSent) {
            Log.w(TAG, "handleAirplaneModeEnabled called on destroyed service or already sent")
            return
        }

        acquireWakeLock("airplane_mode")

        VpnLogger.critical(TAG, "🚨 AIRPLANE MODE ENABLED - Immediate shutdown")
        VpnLogger.markCrashScenario("AIRPLANE_MODE_ENABLED")

        Log.e(TAG, "✈️ Airplane mode enabled - stopping VPN immediately")

        isNormalStop = false
        deathEventSent = true

        // ✅ CRITICAL: Show notification IMMEDIATELY from VPN service (not AutoReconnect)
        // This ensures notification persists even if AutoReconnectService stops quickly
        showDisconnectNotification("VPN Disconnected", "Airplane mode enabled")

        // ⭐ USE centralized cleanup
        serviceScope.launch {
            cleanupVpn("airplane_mode")

            withContext(Dispatchers.Main) {
                setVpnState(false)

                // Send airplane_mode death event (AutoReconnectService will NOT reconnect)
                notifyFlutterVpnDeath("airplane_mode", "Airplane mode enabled")

                Thread {
                    try {
                        notifyBackendDisconnect()
                        Log.d(TAG, "✅ Backend notified of airplane mode disconnect")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to notify backend: ${e.message}")
                    }

                    Thread.sleep(1000)
                    releaseWakeLock("airplane_mode_handled")
                    stopSelf()
                }.start()
            }
        }
    }

    // ✅ NEW: Show disconnect notification directly from VPN service
    private fun showDisconnectNotification(title: String, message: String) {
        try {
            VpnLogger.log(TAG, "📢 Showing disconnect notification: $title - $message")
            Log.d(TAG, "📢 Showing disconnect notification from MyVpnService")

            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notificationManager = getSystemService(NotificationManager::class.java)

            // Create high-priority channel if needed
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    "vpn_disconnect",
                    "VPN Disconnect Alerts",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Important alerts when VPN disconnects"
                    enableVibration(true)
                    setShowBadge(true)
                }
                notificationManager.createNotificationChannel(channel)
            }

            val notification = NotificationCompat.Builder(this, "vpn_disconnect")
                .setContentTitle(title)
                .setContentText(message)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setOngoing(false)
                .build()

            notificationManager.notify(9999, notification)  // Use different ID from AutoReconnect

            VpnLogger.log(TAG, "✅ Disconnect notification posted from MyVpnService (ID: 9999)")
            Log.d(TAG, "✅ Disconnect notification posted successfully from MyVpnService")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "❌ Failed to show disconnect notification", e)
            Log.e(TAG, "❌ Failed to show notification: ${e.message}", e)
        }
    }

    // ✅ NEW: Handle VPN network lost (instant detection)
    private fun handleVpnNetworkLost() {
        if (!isServiceAlive.get() || deathEventSent) {
            Log.w(TAG, "handleVpnNetworkLost called on destroyed service or already sent")
            return
        }

        acquireWakeLock("vpn_death")

        VpnLogger.critical(TAG, "🚨 VPN NETWORK LOST DETECTED (Layer 1 instant)")
        VpnLogger.markCrashScenario("VPN_NETWORK_LOST")

        Log.e(TAG, "🔴 VPN network disappeared - checking underlying network")

        isNormalStop = false
        deathEventSent = true

        // ⭐ SMART DETECTION: Check if underlying network exists
        val hasNetwork = hasUnderlyingNetwork()

        if (hasNetwork) {
            Log.e(TAG, "📶 UNDERLYING NETWORK EXISTS → VPN tunnel broken")
            VpnLogger.log(TAG, "🔴 VPN BROKEN: Network available but VPN died")
        } else {
            Log.w(TAG, "📶 NO UNDERLYING NETWORK → Airplane mode or network lost")
            VpnLogger.log(TAG, "⏳ NETWORK LOST: No WiFi/Cellular/Ethernet detected")
        }

        // ⭐ USE centralized cleanup
        serviceScope.launch {
            cleanupVpn("network_lost")

            withContext(Dispatchers.Main) {
                setVpnState(false)

                // Determine reason based on network availability
                val reason = if (hasNetwork) "vpn_broken" else "network_lost"
                val message = if (hasNetwork) {
                    "VPN tunnel broken - reconnecting..."
                } else {
                    "No internet connection - waiting for network..."
                }

                notifyFlutterVpnDeath(reason, message)

                Thread {
                    try {
                        notifyBackendDisconnect()
                        Log.d(TAG, "✅ Backend notified of disconnect")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to notify backend: ${e.message}")
                    }

                    Thread.sleep(1000)
                    releaseWakeLock("vpn_death_handled")
                    stopSelf()
                }.start()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            // ⭐ STEP 1: Start foreground IMMEDIATELY (before ANY other code)
            val notification = createNotification("Vulcain VPN", "Connecting...")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }

            VpnLogger.log(TAG, "✅ Started foreground immediately")

            // ⭐ STEP 2: Handle STOP action
            when (intent?.action) {
                "STOP_VPN" -> {
                    VpnLogger.log(TAG, "🛑 STOP_VPN action received")
                    isNormalStop = true
                    stopVpnService()
                    return START_NOT_STICKY
                }
            }

            // ⭐ STEP 3: Check notifications (AFTER startForeground)
            if (!areNotificationsEnabled()) {
                VpnLogger.log(TAG, "⚠️ Notifications disabled - showing error")

                // Show a system dialog or toast since we can't show notification
                try {
                    val errorIntent = Intent(this, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        putExtra("error", "notifications_disabled")
                    }
                    startActivity(errorIntent)
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "Failed to show error", e)
                }

                // Stop service gracefully (already called startForeground, so safe)
                stopSelf()
                return START_NOT_STICKY
            }

            // ⭐ STEP 4: Cache config/token
            intent?.getStringExtra("VPN_CONFIG")?.let { config ->
                cachedConfig = config
                VpnLogger.log(TAG, "✅ Config cached (${config.length} chars)")
            }

            intent?.getStringExtra("ACCESS_TOKEN")?.let { token ->
                cachedAccessToken = token
                VpnLogger.log(TAG, "✅ Access token cached")
            }

            // ⭐ STEP 5: DEFENSIVE - Detect stale state
            val vpnPrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
            val storedVpnRunning = vpnPrefs.getBoolean("vpn_running", false)
            val actuallyRunning = isVpnActive() // Check actual VPN state

            if (storedVpnRunning && !actuallyRunning) {
                VpnLogger.log(TAG, "⚠️ STALE STATE DETECTED!")
                VpnLogger.log(TAG, "   Stored state: vpn_running=true")
                VpnLogger.log(TAG, "   Actual state: VPN not active")
                VpnLogger.log(TAG, "   Likely cause: App updated or crashed while VPN running")

                // Clear stale state
                vpnPrefs.edit()
                    .putBoolean("vpn_running", false)
                    .putBoolean("vpn_was_running", false)
                    .apply()

                VpnLogger.log(TAG, "✅ Stale state cleared - will start fresh")
            }

            // ⭐ STEP 6: Start VPN (now safe from stale state)
            if (!getVpnState()) {
                VpnLogger.log(TAG, "🚀 VPN not running - starting VPN service")
                startVpnService()
            } else {
                VpnLogger.log(TAG, "ℹ️ VPN already running - skipping start")
            }

            return START_STICKY

        } catch (e: Exception) {
            VpnLogger.error(TAG, "❌ onStartCommand failed", e)

            // Try to show error to user
            try {
                showCriticalErrorNotification("VPN failed to start: ${e.message}")
            } catch (e2: Exception) {
                VpnLogger.error(TAG, "Failed to show error notification", e2)
            }

            stopSelf()
            return START_NOT_STICKY
        }
    }

    // ⭐ Helper: Check actual VPN state (not SharedPreferences)
    private fun isVpnActive(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val activeNetwork = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(activeNetwork) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to check VPN state", e)
            false
        }
    }

    // ⭐ Helper: Show critical error notification
    private fun showCriticalErrorNotification(message: String) {
        try {
            createNotificationChannelIfNeeded() // Make sure channel exists

            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("vpn_error", message)
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("VPN Error")
                .setContentText(message)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(8888, notification)

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to show critical error", e)
        }
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                createNotificationChannel()
            }
        }
    }

    private fun startVpnService() {
        // ⭐ NEW: Prevent concurrent starts
        synchronized(this) {
            if (isStarting) {
                VpnLogger.log(TAG, "⚠️ VPN already starting - ignoring duplicate request")
                Log.w(TAG, "⚠️ VPN start already in progress - ignoring duplicate")
                return
            }
            isStarting = true
        }

        VpnLogger.log(TAG, "🟢 Starting VPN service")
        VpnLogger.markCrashScenario("VPN_START")
        Log.d(TAG, "Starting VPN service")

        // ✅ Acquire wake lock during VPN start
        acquireWakeLock("vpn_start")

        isNormalStop = false
        deathEventSent = false
        consecutiveFailures = 0
        lastSuccessfulPing = System.currentTimeMillis()

        // ✅ Reset 403 counter
        auth403Count.set(0)
        last403Time.set(0L)
        isHandlingSubscriptionExpired.set(false)

        synchronized(prefsLock) {
            prefs.edit().putLong(KEY_LAST_SEEN_AT, System.currentTimeMillis()).apply()
        }

        Thread {
            try {
                VpnLogger.log(TAG, "🔐 Checking subscription status...")

                // ✅ Check subscription using API Key
                val deviceId = getSecureValue("device_id")
                val apiKey = getSecureValue("api_key")

                if (deviceId == null || apiKey == null) {
                    VpnLogger.log(TAG, "❌ No device credentials available")

                    setVpnState(false)  // ✅ AJOUTE: Reset state

                    mainHandler.post {
                        // ✅ AJOUTE: Show notification to user
                        showAuthFailedNotification()

                        // ✅ AJOUTE: Remove foreground notification
                        stopForeground(STOP_FOREGROUND_REMOVE)

                        releaseWakeLock("vpn_start_failed")
                        synchronized(this@MyVpnService) { isStarting = false }
                        stopSelf()
                    }

                    notifyFlutterVpnDeath("auth_required", "Device not registered")
                    return@Thread
                }

                VpnLogger.log(TAG, "✅ Credentials found - proceeding (subscription validated by backend)")

                // ⭐ NEW: Clean up any existing instances before starting
                try {
                    VpnLogger.log(TAG, "🧹 Ensuring clean state before start...")
                    closeCommandServer()

                    // Small delay to ensure port is released
                    Thread.sleep(500)
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "Error during pre-start cleanup", e)
                }

                VpnLogger.log(TAG, "📥 Getting VPN config...")
                val config = getConfig()
                VpnLogger.log(TAG, "✅ Config loaded (${config.length} chars)")

                val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

                VpnLogger.log(TAG, "🌐 Starting network monitor...")
                runBlocking {
                    DefaultNetworkMonitor.start(connectivityManager)
                }
                VpnLogger.log(TAG, "✅ Network monitor started")

                VpnLogger.log(TAG, "🚀 Creating libbox command server...")
                Libbox.setMemoryLimit(true)

                // Validate before handing the config to libbox. Without this a schema
                // problem surfaces as an opaque failure inside startOrReloadService.
                try {
                    Libbox.checkConfig(config)
                    VpnLogger.log(TAG, "✅ Config validated by libbox")
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "❌ Config REJECTED by libbox: ${e.message}", e)
                    throw e
                }

                val server = Libbox.newCommandServer(VulcainCommandServerHandler(), this)
                // Assign before start(): libbox callbacks can fire during startup.
                commandServer = server

                // start() brings up the IPC socket only - it does NOT start the tunnel.
                server.start()
                VpnLogger.log(TAG, "✅ Command server started")

                // startOrReloadService() is what actually starts the tunnel.
                server.startOrReloadService(config, OverrideOptions())
                VpnLogger.log(TAG, "✅ Libbox service started successfully")

                setVpnState(true)
                VpnLogger.log(TAG, "✅ VPN state set to running")

                synchronized(prefsLock) {
                    prefs.edit().putLong(KEY_START_TIME, System.currentTimeMillis()).apply()
                }

                val connectedNotification = createNotification("Vulcain VPN", "Connected")
                val notificationManager = getSystemService(NotificationManager::class.java)
                notificationManager.notify(NOTIFICATION_ID, connectedNotification)

                notifyFlutterVpnState("connected", "VPN connected successfully")
                Log.d(TAG, "✅ VPN started successfully")
                VpnLogger.log(TAG, "✅ VPN FULLY CONNECTED")

                // Clear starting flag after successful start
                synchronized(this@MyVpnService) { isStarting = false }

                // Start watchdog service
                startWatchdogService()

                Handler(Looper.getMainLooper()).postDelayed({
                    try {
                        val updatedNotification = createNotification("Vulcain VPN", "Connected")
                        notificationManager.notify(NOTIFICATION_ID, updatedNotification)
                        VpnLogger.log(TAG, "✅ Notification priority refreshed after watchdog start")
                    } catch (e: Exception) {
                        VpnLogger.error(TAG, "Failed to refresh notification", e)
                    }
                }, 500)

                // Start heartbeat monitoring (backup detection)
                startHeartbeatMonitoring()

            } catch (e: Exception) {
                VpnLogger.error(TAG, "❌ VPN START FAILED", e)
                Log.e(TAG, "❌ Failed to start VPN", e)

                setVpnState(false)

                mainHandler.post {
                    // ✅ AJOUTE: Remove foreground notification
                    stopForeground(STOP_FOREGROUND_REMOVE)

                    releaseWakeLock("vpn_start_error")
                    synchronized(this@MyVpnService) { isStarting = false }
                    stopSelf()
                }

                notifyFlutterVpnState("error", "Failed to start: ${e.message}")
            }
        }.start()
    }

    // ✅ NEW: Handle subscription expiry detected via 403 errors
    private fun handleSubscriptionExpired() {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "handleSubscriptionExpired called on destroyed service")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        if (!getVpnState()) {
            Log.w(TAG, "Already disconnected, ignoring subscription expiry")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        Log.e(TAG, "🔴 Stopping VPN - Subscription expired (detected via 403 errors)")
        VpnLogger.critical(TAG, "💀 VPN DIED: Subscription expired (403 detection)")

        isNormalStop = false
        deathEventSent = true

        stopHeartbeatMonitoring()

        try {
            closeCommandServer()
            fileDescriptor?.close()
            fileDescriptor = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN: ${e.message}")
        }

        setVpnState(false)

        // ✅ ADD THIS: Show notification to user
        showSubscriptionExpiredNotification()

        notifyFlutterVpnDeath("subscription_expired", "Your VPN subscription has expired")

        auth403Count.set(0)

        Thread {
            Thread.sleep(300)
            isHandlingSubscriptionExpired.set(false)
            releaseWakeLock("subscription_expired")
            stopSelf()
        }.start()
    }

    // ✅ NEW: Handle 403 errors by verifying subscription status first
    private fun handle403Errors() {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "handle403Errors called on destroyed service")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        if (!getVpnState()) {
            Log.w(TAG, "Already disconnected, ignoring 403 errors")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        Log.e(TAG, "🔍 Verifying subscription status via API (checking if 403 is subscription vs credentials)")
        VpnLogger.critical(TAG, "🔍 Verifying subscription status after 403 errors")

        // Check subscription status in background thread
        Thread {
            try {
                val deviceId = getSecureValue("device_id")
                val apiKey = getSecureValue("api_key")

                if (deviceId == null || apiKey == null) {
                    Log.e(TAG, "❌ No credentials - cannot verify subscription")
                    mainHandler.post {
                        // Treat as auth failure
                        handleAuthenticationFailure("device_revoked", "Device credentials missing")
                    }
                    return@Thread
                }

                // Call API to check subscription
                val subscriptionStatus = runBlocking {
                    checkSubscription(deviceId, apiKey)
                }

                Log.d(TAG, "📋 Subscription API returned: $subscriptionStatus")

                mainHandler.post {
                    when (subscriptionStatus) {
                        "expired", "canceled" -> {
                            // API confirms subscription is expired - stop permanently
                            Log.e(TAG, "✅ API CONFIRMED: Subscription expired")
                            VpnLogger.critical(TAG, "✅ API CONFIRMED: Subscription actually expired")
                            handleSubscriptionExpired()
                        }
                        "active" -> {
                            // API says subscription is active but we're getting 403s
                            // This means CREDENTIALS expired, not subscription
                            Log.e(TAG, "🔑 CREDENTIALS EXPIRED: Subscription active but getting 403s")
                            VpnLogger.critical(TAG, "🔑 CREDENTIALS EXPIRED: Need fresh credentials from /api/connect")
                            handleCredentialsExpired()
                        }
                        "auth_failed" -> {
                            // Device credentials are invalid
                            Log.e(TAG, "🚫 DEVICE REVOKED: API returned auth_failed")
                            VpnLogger.critical(TAG, "🚫 DEVICE REVOKED: Device no longer authorized")
                            handleAuthenticationFailure("device_revoked", "Device credentials revoked")
                        }
                        else -> {
                            // API check failed or returned unknown - treat as network issue
                            Log.w(TAG, "⚠️ API check inconclusive ($subscriptionStatus) - treating as credentials issue")
                            VpnLogger.log(TAG, "⚠️ API check inconclusive - assuming credentials expired")
                            handleCredentialsExpired()
                        }
                    }
                }

            } catch (e: Exception) {
                Log.e(TAG, "API verification failed: ${e.message}")
                VpnLogger.error(TAG, "API verification error", e)

                mainHandler.post {
                    // If we can't verify, assume credentials expired (safer to reconnect than stop)
                    Log.w(TAG, "⚠️ Cannot verify subscription - assuming credentials expired")
                    handleCredentialsExpired()
                }
            }
        }.start()
    }

    // ✅ NEW: Handle credentials expiry (reconnectable)
    private fun handleCredentialsExpired() {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "handleCredentialsExpired called on destroyed service")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        Log.e(TAG, "🔑 Stopping VPN - Credentials expired (will reconnect with fresh credentials)")
        VpnLogger.critical(TAG, "💀 VPN DIED: Credentials expired (reconnectable)")

        isNormalStop = false
        deathEventSent = true

        stopHeartbeatMonitoring()

        serviceScope.launch {
            cleanupVpn("credentials_expired")

            withContext(Dispatchers.Main) {
                setVpnState(false)

                // ✅ Send credentials_expired death event (AutoReconnectService WILL reconnect)
                notifyFlutterVpnDeath("credentials_expired", "VPN credentials expired - reconnecting with fresh credentials")

                auth403Count.set(0)

                Thread {
                    try {
                        notifyBackendDisconnect()
                        Log.d(TAG, "✅ Backend notified of credentials expiry")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to notify backend: ${e.message}")
                    }

                    Thread.sleep(300)
                    isHandlingSubscriptionExpired.set(false)
                    releaseWakeLock("credentials_expired")
                    stopSelf()
                }.start()
            }
        }
    }

    // ✅ NEW: Handle authentication failure (device revoked, etc.)
    private fun handleAuthenticationFailure(reason: String, message: String) {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "handleAuthenticationFailure called on destroyed service")
            isHandlingSubscriptionExpired.set(false)
            return
        }

        Log.e(TAG, "🚫 Stopping VPN - Authentication failure: $reason")
        VpnLogger.critical(TAG, "💀 VPN DIED: $reason")

        isNormalStop = false
        deathEventSent = true

        stopHeartbeatMonitoring()

        serviceScope.launch {
            cleanupVpn(reason)

            withContext(Dispatchers.Main) {
                setVpnState(false)

                // Show notification
                showAuthFailedNotification()

                // Send death event (non-reconnectable)
                notifyFlutterVpnDeath(reason, message)

                auth403Count.set(0)

                Thread {
                    try {
                        notifyBackendDisconnect()
                        Log.d(TAG, "✅ Backend notified of $reason")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to notify backend: ${e.message}")
                    }

                    Thread.sleep(300)
                    isHandlingSubscriptionExpired.set(false)
                    releaseWakeLock(reason)
                    stopSelf()
                }.start()
            }
        }
    }

    private fun showSubscriptionExpiredNotification() {
        try {
            val notificationIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                putExtra("open_from_notification", true)
            }

            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                notificationIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Subscription Expired")
                .setContentText("Your VPN subscription has expired. Tap to renew.")
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(999, notification)  // Different ID from VPN notification

            Log.d(TAG, "✅ Subscription expired notification shown")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show subscription expired notification: ${e.message}")
        }
    }

    private fun showAuthFailedNotification() {
        try {
            val notificationIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                putExtra("open_from_notification", true)
            }

            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                notificationIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Login Required")
                .setContentText("Your session has expired. Please login again.")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(998, notification)  // Different ID from subscription (999)

            Log.d(TAG, "✅ Auth failed notification shown")
            VpnLogger.log(TAG, "✅ Auth failed notification shown")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show auth failed notification: ${e.message}")
            VpnLogger.error(TAG, "Failed to show auth failed notification", e)
        }
    }

    private suspend fun checkSubscription(deviceId: String, apiKey: String): String {
        return withContext(Dispatchers.IO) {
            try {
                VpnLogger.log(TAG, "Making API request to check subscription...")
                val url = java.net.URL("https://api.vulcainvpn.com/api/subscription/$deviceId")
                val connection = url.openConnection() as javax.net.ssl.HttpsURLConnection

                connection.requestMethod = "GET"
                connection.setRequestProperty("X-Api-Key", apiKey)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = 10000
                connection.readTimeout = 10000

                val responseCode = connection.responseCode
                VpnLogger.log(TAG, "Subscription API response code: $responseCode")

                when (responseCode) {
                    200 -> {
                        val response = connection.inputStream.bufferedReader().use { it.readText() }
                        VpnLogger.log(TAG, "API response body: ${response.take(200)}...")

                        if (response.trimStart().startsWith("<!DOCTYPE", ignoreCase = true) ||
                            response.trimStart().startsWith("<html", ignoreCase = true)) {
                            VpnLogger.log(TAG, "⚠️ API returned HTML - authentication failed")
                            return@withContext "auth_failed"
                        }

                        val json = org.json.JSONObject(response)
                        val subscription = json.getJSONObject("subscription")
                        val status = subscription.getString("status")

                        VpnLogger.log(TAG, "✅ Subscription status from API: $status")
                        return@withContext status
                    }
                    401, 403 -> {
                        VpnLogger.log(TAG, "⚠️ Authentication failed ($responseCode) - device revoked or invalid")
                        return@withContext "auth_failed"
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

    // ✅ NEW: Wrapper to check subscription status (gets token automatically)
    private suspend fun checkSubscriptionStatus(): String {
        val deviceId = getSecureValue("device_id")
        val apiKey = getSecureValue("api_key")

        if (deviceId == null || apiKey == null) {
            Log.w(TAG, "❌ No device credentials available for subscription check")
            return "auth_failed"
        }

        VpnLogger.log(TAG, "🔍 Checking subscription with device_id: ${deviceId.take(8)}...")
        return checkSubscription(deviceId, apiKey)
    }

    private fun getConfig(): String {
        // 1. Try memory cache
        cachedConfig?.let { return it }

        // 2. Try encrypted SharedPreferences (survives service restart) ✅
        try {
            val masterKey = MasterKey.Builder(applicationContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()

            val prefs = EncryptedSharedPreferences.create(
                applicationContext,
                "FlutterSecureStorage",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

            val prefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg"
            val savedConfig = prefs.getString("${prefix}_vpn_config", null)

            if (savedConfig != null) {
                Log.d(TAG, "✅ Using saved config from SharedPreferences (${savedConfig.length} chars)")
                VpnLogger.log(TAG, "✅ Config loaded from encrypted storage")
                cachedConfig = savedConfig
                return savedConfig
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to read config from encrypted storage", e)
        }

        // 3. Fallback to bundled config (should rarely happen)
        Log.w(TAG, "⚠️ No saved config, using bundled config.json")
        VpnLogger.log(TAG, "⚠️ Using fallback bundled config")
        return try {
            assets.open("config.json").bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            throw IllegalStateException("No config available")
        }
    }

    // ✅ IMPROVED: Heartbeat with better reliability (Layer 2 backup)
    private fun startHeartbeatMonitoring() {
        stopHeartbeatMonitoring()
        val logMsg = "💓 Starting heartbeat (Layer 2 backup, every ${HEARTBEAT_INTERVAL_MS/1000}s, ${MAX_CONSECUTIVE_FAILURES} failures = ${(HEARTBEAT_INTERVAL_MS * MAX_CONSECUTIVE_FAILURES)/1000}s timeout)"
        Log.d(TAG, logMsg)
        VpnLogger.log(TAG, logMsg)

        heartbeatJob = serviceScope.launch(Dispatchers.IO) {
            while (isActive && getVpnState() && isServiceAlive.get()) {
                delay(HEARTBEAT_INTERVAL_MS)

                if (!isServiceAlive.get()) {
                    Log.d(TAG, "💓 Heartbeat stopped - service destroyed")
                    break
                }

                // ✅ FIXED: Send backend heartbeat with logging
                sendBackendHeartbeat()

                // ✅ NEW: Check subscription every 30 heartbeats (5 minutes)
                heartbeatCounter++
                if (heartbeatCounter >= 30) {
                    heartbeatCounter = 0
                    try {
                        val subscriptionStatus = checkSubscriptionStatus()

                        // ✅ FIXED: Handle different failure cases appropriately
                        when (subscriptionStatus) {
                            "expired" -> {
                                // Subscription actually expired - kill VPN
                                val msg = "🔴 Subscription expired - stopping VPN"
                                Log.e(TAG, msg)
                                VpnLogger.log(TAG, msg)

                                mainHandler.post {
                                    acquireWakeLock("subscription_expired")
                                    handleSubscriptionExpired()
                                }
                                break  // Exit heartbeat loop
                            }
                            "auth_failed" -> {
                                val msg = "🔴 Device credentials invalid - stopping VPN"
                                Log.e(TAG, msg)
                                VpnLogger.log(TAG, msg)

                                mainHandler.post {
                                    acquireWakeLock("device_revoked")
                                    isNormalStop = false
                                    deathEventSent = true
                                    stopHeartbeatMonitoring()

                                    try {
                                        closeCommandServer()
                                        fileDescriptor?.close()
                                        fileDescriptor = null
                                    } catch (e: Exception) {
                                        Log.e(TAG, "Error closing VPN: ${e.message}")
                                    }

                                    setVpnState(false)
                                    notifyFlutterVpnDeath("device_revoked", "Device credentials revoked - please login again")

                                    Thread {
                                        Thread.sleep(300)
                                        releaseWakeLock("device_revoked_handled")
                                        stopSelf()
                                    }.start()
                                }
                                break
                            }
                            "active" -> {
                                Log.d(TAG, "✅ Periodic subscription check: active")
                            }
                            else -> {
                                // "unknown" or other - network error, don't kill VPN
                                Log.w(TAG, "⚠️ Periodic subscription check returned: $subscriptionStatus (continuing VPN)")
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Periodic subscription check failed: ${e.message}")
                        // Continue heartbeat even if subscription check fails
                    }
                }

                try {
                    val isReachable = performHeartbeatCheck()

                    if (isReachable) {
                        if (consecutiveFailures > 0) {
                            val msg = "💚 Heartbeat recovered after $consecutiveFailures failures"
                            Log.d(TAG, msg)
                            VpnLogger.log(TAG, msg)
                        }
                        consecutiveFailures = 0
                        lastSuccessfulPing = System.currentTimeMillis()

                        synchronized(prefsLock) {
                            prefs.edit().putLong(KEY_LAST_SEEN_AT, System.currentTimeMillis()).apply()
                        }
                    } else {
                        consecutiveFailures++
                        val timeSinceLastSuccess = (System.currentTimeMillis() - lastSuccessfulPing) / 1000

                        val msg = "💔 Heartbeat failed ($consecutiveFailures/$MAX_CONSECUTIVE_FAILURES) - Last success: ${timeSinceLastSuccess}s ago"
                        Log.w(TAG, msg)
                        VpnLogger.log(TAG, msg)

                        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
                            val thresholdMsg = "🚨 HEARTBEAT THRESHOLD REACHED - Triggering failure handler"
                            Log.e(TAG, thresholdMsg)
                            VpnLogger.log(TAG, thresholdMsg)
                            // ✅ NEW: Acquire wake lock before handling failure
                            mainHandler.post {
                                acquireWakeLock("heartbeat_failure")
                            }
                            handleHeartbeatFailure()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Heartbeat check error: ${e.message}")
                    VpnLogger.error(TAG, "Heartbeat check error", e)
                }
            }
        }
    }

    private fun stopHeartbeatMonitoring() {
        heartbeatJob?.let { job ->
            if (job.isActive) {
                job.cancel()
                Log.d(TAG, "💓 Heartbeat job cancelled")
            }
        }
        heartbeatJob = null
        consecutiveFailures = 0
        heartbeatCounter = 0  // ✅ Reset subscription check counter
    }

    // ✅ FIXED: Heartbeat now pings the backend instead of 1.1.1.1/cdn-cgi/trace.
    // The Cloudflare endpoint was being blocked by the Paris VPN server, causing
    // false "tunnel broken" detections every 40s. The backend heartbeat endpoint
    // already works reliably (proven by sendBackendHeartbeat() succeeding), so
    // we reuse it here — it tests DNS + VPN tunnel + server reachability in one shot.
    private suspend fun performHeartbeatCheck(): Boolean {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "performHeartbeatCheck called on destroyed service")
            return false
        }

        return withContext(Dispatchers.IO) {
            try {
                val deviceId = getSecureValue("device_id") ?: run {
                    VpnLogger.log(TAG, "💔 Heartbeat: No device_id available")
                    return@withContext false
                }
                val apiKey = getSecureValue("api_key") ?: run {
                    VpnLogger.log(TAG, "💔 Heartbeat: No api_key available")
                    return@withContext false
                }

                // POST to our own backend — routes through VPN tunnel, uses real auth.
                // If the tunnel is broken, this will throw (timeout or connection refused).
                // If credentials are invalid, we get a non-200 but still know tunnel works.
                val url = URL("https://api.vulcainvpn.com/api/heartbeat/$deviceId")
                val connection = url.openConnection() as HttpsURLConnection

                // DO NOT protect() — must route through VPN tunnel
                connection.requestMethod = "POST"
                connection.setRequestProperty("X-Api-Key", apiKey)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = HEARTBEAT_TIMEOUT_MS
                connection.readTimeout = HEARTBEAT_TIMEOUT_MS

                val responseCode = connection.responseCode
                connection.disconnect()

                // Any HTTP response (200, 401, 403, 500...) means the tunnel is alive
                // and DNS + routing are working. Only exceptions mean the tunnel is dead.
                VpnLogger.log(TAG, "💚 Heartbeat: VPN tunnel healthy (HTTP $responseCode)")
                Log.d(TAG, "💚 Heartbeat: VPN tunnel healthy (HTTP $responseCode)")
                return@withContext true

            } catch (e: java.net.UnknownHostException) {
                VpnLogger.log(TAG, "💔 Heartbeat: DNS resolution failed (VPN tunnel broken)")
                Log.e(TAG, "💔 Heartbeat: DNS failed - ${e.message}")
                return@withContext false

            } catch (e: java.net.SocketTimeoutException) {
                VpnLogger.log(TAG, "💔 Heartbeat: Connection timeout (VPN tunnel broken)")
                Log.e(TAG, "💔 Heartbeat: Timeout - ${e.message}")
                return@withContext false

            } catch (e: Exception) {
                VpnLogger.log(TAG, "💔 Heartbeat: Connection failed - ${e.message}")
                Log.e(TAG, "💔 Heartbeat: Failed - ${e.message}")
                return@withContext false
            }
        }
    }

    private fun getUnderlyingNetwork(): Network? {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

            // Find non-VPN network
            for (network in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue

                // Skip VPN networks
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    continue
                }

                // Return first WiFi or Cellular network
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                    Log.d(TAG, "📡 Found underlying network: WiFi=${caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)}, Cellular=${caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)}")
                    return network
                }
            }

            Log.w(TAG, "⚠️ No underlying network found")
            null
        } catch (e: Exception) {
            Log.e(TAG, "Error getting underlying network: ${e.message}")
            null
        }
    }

    private fun sendBackendHeartbeat() {
        Thread {
            try {
                val deviceId = getSecureValue("device_id") ?: return@Thread
                val apiKey = getSecureValue("api_key") ?: return@Thread

                // ⭐ Send through VPN tunnel (no network binding needed)
                val url = URL("https://api.vulcainvpn.com/api/heartbeat/$deviceId")
                val connection = url.openConnection() as HttpsURLConnection

                connection.requestMethod = "POST"
                connection.setRequestProperty("X-Api-Key", apiKey)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = 5000
                connection.readTimeout = 5000

                val responseCode = connection.responseCode
                connection.disconnect()

                when (responseCode) {
                    200 -> {
                        Log.d(TAG, "✅ Backend heartbeat successful")
                        VpnLogger.log(TAG, "✅ Backend heartbeat successful")
                    }
                    else -> {
                        Log.w(TAG, "⚠️ Backend heartbeat: HTTP $responseCode")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Backend heartbeat error: ${e.message}")
            }
        }.start()
    }

    private suspend fun handleHeartbeatFailure() {
        VpnLogger.critical(TAG, "🚨 HEARTBEAT FAILURE DETECTED (Layer 2 backup)")
        VpnLogger.markCrashScenario("HEARTBEAT_FAILURE")

        if (!isServiceAlive.get()) {
            Log.w(TAG, "handleHeartbeatFailure called on destroyed service")
            return
        }

        withContext(Dispatchers.Main) {
            Log.e(TAG, "🚨 HEARTBEAT FAILURE DETECTED - checking underlying network")

            // ⭐ SMART DETECTION: Check if underlying network exists
            val hasNetwork = hasUnderlyingNetwork()

            if (hasNetwork) {
                Log.e(TAG, "📶 UNDERLYING NETWORK EXISTS → VPN tunnel broken")
                VpnLogger.log(TAG, "🔴 VPN BROKEN: Network available but heartbeat fails")
            } else {
                Log.w(TAG, "📶 NO UNDERLYING NETWORK → Airplane mode or network lost")
                VpnLogger.log(TAG, "⏳ NETWORK LOST: No WiFi/Cellular/Ethernet detected")
            }

            if (!isServiceAlive.get()) return@withContext

            VpnLogger.log(TAG, "🔴 Stopping service and triggering auto-reconnect")

            isNormalStop = false
            deathEventSent = true

            // ⭐ USE centralized cleanup
            cleanupVpn("heartbeat_failure")

            setVpnState(false)

            val reason = if (hasNetwork) "vpn_broken" else "network_lost"
            val message = if (hasNetwork) {
                "VPN tunnel broken - reconnecting..."
            } else {
                "No internet connection - waiting for network..."
            }

            notifyFlutterVpnDeath(reason, message)

            // Move backend notification to separate thread
            Thread {
                try {
                    notifyBackendDisconnect()
                    Log.d(TAG, "✅ Backend notified of disconnect")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to notify backend: ${e.message}")
                }

                // Final delay before stopping service
                Thread.sleep(1000)
                releaseWakeLock("heartbeat_failure_handled")
                stopSelf()
            }.start()

            consecutiveFailures = 0
        }
    }

    private fun notifyBackendDisconnect() {
        val deviceId = getSecureValue("device_id") ?: return
        val apiKey = getSecureValue("api_key") ?: return

        val url = URL("https://api.vulcainvpn.com/api/disconnect/$deviceId")
        val connection = url.openConnection() as HttpsURLConnection

        connection.requestMethod = "POST"
        connection.setRequestProperty("X-Api-Key", apiKey)
        connection.connectTimeout = 5000
        connection.readTimeout = 5000

        connection.responseCode // Execute request
        connection.disconnect()
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

    private fun stopVpnService() {
        Log.d(TAG, "Stopping VPN service (normal stop: $isNormalStop)")

        stopHeartbeatMonitoring()

        try {
            runBlocking {
                try {
                    DefaultNetworkMonitor.stop()
                } catch (e: Exception) {
                    Log.e(TAG, "Error stopping network monitor: ${e.message}")
                }
            }
            cachedConfig = null
            cachedInterfaces = null
            fileDescriptor?.close()
            fileDescriptor = null
            closeCommandServer()

            // Stop watchdog service
            stopWatchdogService()

            setVpnState(false)

            synchronized(prefsLock) {
                prefs.edit().remove(KEY_START_TIME).apply()
            }

            // ✅ NEW: Notify backend of disconnect
            if (isNormalStop) {
                // User-initiated disconnect - notify backend in separate thread
                Thread {
                    try {
                        notifyBackendDisconnect()
                        Log.d(TAG, "✅ Backend notified of user disconnect")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to notify backend: ${e.message}")
                    }
                }.start()

                notifyFlutterVpnState("disconnected", "VPN disconnected by user")
            } else {
                notifyFlutterVpnState("died", "VPN stopped unexpectedly")
            }

            releaseWakeLock("vpn_stop")

            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "🔴 Service destroyed (normal stop: $isNormalStop)")

        isServiceAlive.set(false)

        // ✅ NEW: Unregister VPN death monitor
        unregisterVpnDeathMonitor()

        // ✅ NEW: Unregister airplane mode monitor
        unregisterAirplaneModeReceiver()

        try {
            stopHeartbeatMonitoring()
            serviceScope.cancel()
            Log.d(TAG, "✅ Service scope cancelled")
        } catch (e: Exception) {
            Log.e(TAG, "Error cancelling service scope: ${e.message}")
        }

        setVpnState(false)

        synchronized(prefsLock) {
            prefs.edit().remove(KEY_START_TIME).apply()
        }

        // ✅ FIXED: Only broadcast "service_killed" if service was ACTUALLY RUNNING
        if (!isNormalStop && !deathEventSent) {
            val wasRunning = synchronized(prefsLock) {
                prefs.getBoolean(KEY_IS_RUNNING, false)
            }

            if (wasRunning) {
                Log.e(TAG, "⚠️ VPN SERVICE KILLED UNEXPECTEDLY BY ANDROID!")

                try {
                    val deathPrefs = getSharedPreferences("vpn_state", Context.MODE_PRIVATE)
                    deathPrefs.edit().apply {
                        putString("death_reason", "service_killed")
                        putString("death_message", "Android killed VPN service (low memory or system cleanup)")
                        putLong("death_timestamp", System.currentTimeMillis())
                        putBoolean("has_unread_death", true)
                        commit()
                    }

                    notifyFlutterVpnDeath("service_killed", "Android killed VPN service (low memory or system cleanup)")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send death event in onDestroy: ${e.message}")
                }
            } else {
                Log.d(TAG, "Service destroyed but VPN was not running - no death event needed")
            }
        }

        // ✅ NEW: Release wake lock on service destruction
        releaseWakeLock("service_destroyed")

        try {
            runBlocking {
                DefaultNetworkMonitor.stop()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping network monitor in onDestroy: ${e.message}")
        }
    }

    override fun onRevoke() {
        super.onRevoke()
        Log.e(TAG, "🔴 VPN PERMISSION REVOKED!")

        isNormalStop = false
        setVpnState(false)
        notifyFlutterVpnDeath("permission_revoked", "VPN permission was revoked")
        releaseWakeLock("permission_revoked")
        stopVpnService()
    }

    private fun notifyFlutterVpnDeath(reason: String, message: String) {
        VpnLogger.critical(TAG, "💀 VPN DIED: reason=$reason, message=$message")
        Log.e(TAG, "💀 VPN DIED: reason=$reason, message=$message")

        try {
            mainHandler.post {
                try {
                    val sink = MainActivity.statusSink
                    if (sink != null) {
                        VpnLogger.log(TAG, "Notifying Flutter via statusSink")
                        sink.success(mapOf(
                            "event" to "vpn_died",
                            "reason" to reason,
                            "message" to message,
                            "timestamp" to System.currentTimeMillis()
                        ))
                    } else {
                        VpnLogger.log(TAG, "⚠️ StatusSink is null, cannot notify Flutter")
                    }
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "Error notifying Flutter via statusSink", e)
                }
            }
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error posting to main handler", e)
        }

        try {
            val intent = Intent("com.vulcain.vpn.VPN_DIED").apply {
                putExtra("reason", reason)
                putExtra("message", message)
                putExtra("timestamp", System.currentTimeMillis())
                setPackage(packageName)
            }
            sendBroadcast(intent)
            VpnLogger.log(TAG, "Broadcast sent successfully")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to send broadcast", e)
        }
    }

    private fun notifyFlutterVpnState(event: String, message: String) {
        mainHandler.post {
            try {
                MainActivity.statusSink?.success(mapOf(
                    "event" to event,
                    "message" to message,
                    "timestamp" to System.currentTimeMillis()
                ))
            } catch (e: Exception) {
                Log.e(TAG, "Error notifying Flutter: ${e.message}")
            }
        }
    }

    // ---- libbox 1.13 CommandServerHandler -------------------------------------
    // Required by Libbox.newCommandServer(). libbox invokes these from its own
    // (Go-owned) threads, so nothing here may block or re-enter libbox.
    private inner class VulcainCommandServerHandler : CommandServerHandler {

        override fun serviceReload() {
            VpnLogger.log(TAG, "📡 serviceReload requested by libbox")
            // Not supported: reconnects are driven by Flutter / AutoReconnectService.
        }

        override fun serviceStop() {
            VpnLogger.log(TAG, "📡 serviceStop requested by libbox")
            // CRITICAL: we are on a libbox-owned thread. Tearing down inline would
            // re-enter the caller (closeService -> back into libbox). Post and return.
            mainHandler.post {
                isNormalStop = true      // otherwise VpnDeathReceiver treats this as a
                deathEventSent = true    // death and starts AutoReconnectService.
                stopVpnService()
            }
        }

        override fun getSystemProxyStatus(): SystemProxyStatus =
            SystemProxyStatus().apply {
                setAvailable(false)
                setEnabled(false)
            }

        override fun setSystemProxyEnabled(isEnabled: Boolean) {
            // n/a: system proxy is not applicable to an Android VpnService tunnel.
        }

        override fun writeDebugMessage(message: String) {
            if (!message.contains("http2: client connection force closed") &&
                !message.contains("operation was canceled")) {
                Log.d(TAG, "libbox: $message")
            }
        }
    }

    // Close order matters: closeService() stops the box, close() tears down the server.
    private fun closeCommandServer() {
        val server = commandServer ?: return
        commandServer = null
        try {
            server.closeService()
            VpnLogger.log(TAG, "✅ box service closed")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error closing box service", e)
        }
        try {
            server.close()
            VpnLogger.log(TAG, "✅ command server closed")
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error closing command server", e)
        }
    }
    // ---------------------------------------------------------------------------

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) {
        try {
            protect(fd)
        } catch (e: Exception) {}
    }

    override fun openTun(options: TunOptions): Int {
        if (Looper.myLooper() == Looper.getMainLooper()) return openTunInternal(options)

        var resultFd: Int? = null
        var exception: Exception? = null
        val latch = CountDownLatch(1)
        mainHandler.post {
            try { resultFd = openTunInternal(options) }
            catch (e: Exception) { exception = e }
            finally { latch.countDown() }
        }
        if (!latch.await(5, TimeUnit.SECONDS)) throw Exception("Timeout waiting for TUN creation")
        exception?.let { throw it }
        return resultFd ?: throw Exception("Failed to get TUN fd")
    }

    private fun openTunInternal(options: TunOptions): Int {
        if (prepare(this) != null) throw Exception("VPN permission not granted")
        val builder = Builder().setSession("VulcainVPN").setMtu(options.mtu.toInt())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val addr = inet4.next()
            builder.addAddress(addr.address(), addr.prefix().toInt())
        }

        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val addr = inet6.next()
            builder.addAddress(addr.address(), addr.prefix().toInt())
        }

        if (options.autoRoute) {
            // ✅ CRITICAL FIX: Always add explicit DNS servers
            builder.addDnsServer("1.1.1.1")   // Cloudflare primary
            builder.addDnsServer("8.8.8.8")   // Google primary
            builder.addRoute("0.0.0.0", 0)

            VpnLogger.log(TAG, "✅ DNS servers configured: 1.1.1.1, 8.8.8.8")
        }

        val pfd = builder.establish() ?: throw Exception("Failed to establish VPN")
        fileDescriptor = pfd
        Log.d(TAG, "✅ TUN established")
        return pfd.fd
    }

    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport? = null

    // NOTE: PlatformInterface.writeLog() no longer exists in libbox 1.13.
    // The 403-sniffing subscription check that used to live here is gone. Subscription
    // expiry is still covered by checkSubscriptionStatus() in the heartbeat loop.
    // handle403Errors()/handleCredentialsExpired()/handleAuthenticationFailure() below
    // are now unreachable - kept for reference. The real fix for credential rotation is
    // to have AutoReconnectService fetch fresh credentials from /api/connect instead of
    // replaying the stored config.

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    // libbox 1.13: returns ConnectionOwner (absorbed packageNameByUid/uidByPackageName,
    // both of which no longer exist on PlatformInterface). Was stubbed at -1 before, so
    // null is the equivalent. If libbox NPEs on this, return
    // ConnectionOwner().apply { setUserId(-1) } instead.
     override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int
    ): ConnectionOwner = ConnectionOwner().apply {
        setUserId(-1)
        setUserName("")
        setProcessPath("")
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.onInterfaceCacheRequest = { network ->
            cachedInterfaces = null
            buildInterfaceCacheForNetwork(network)
        }
        DefaultNetworkMonitor.setListener(listener)
    }

    private fun buildInterfaceCacheForNetwork(network: android.net.Network?) {
        try {
            val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

            val networkInterfaces = try {
                NetworkInterface.getNetworkInterfaces().toList().toMutableList()
            } catch (e: Exception) {
                Log.e(TAG, "Error getting network interfaces: ${e.message}")
                emptyList()
            }

            val interfaces = mutableListOf<LibboxNetworkInterface>()

            if (network != null) {
                val linkProperties = connectivityManager.getLinkProperties(network)
                val networkCapabilities = connectivityManager.getNetworkCapabilities(network)
                val interfaceName = linkProperties?.interfaceName

                if (interfaceName != null &&
                    !interfaceName.startsWith("tun") &&
                    !interfaceName.startsWith("ppp") &&
                    networkCapabilities != null
                ) {
                    val networkInterface = networkInterfaces.find { it.name == interfaceName }
                    if (networkInterface != null) {
                        val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                        interfaces.add(boxInterface)
                    }
                }
            }

            if (interfaces.isEmpty()) {
                for (n in connectivityManager.allNetworks) {
                    try {
                        val linkProperties = connectivityManager.getLinkProperties(n) ?: continue
                        val networkCapabilities = connectivityManager.getNetworkCapabilities(n) ?: continue
                        val interfaceName = linkProperties.interfaceName ?: continue

                        if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) continue

                        val networkInterface = networkInterfaces.find { it.name == interfaceName } ?: continue
                        val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                        interfaces.add(boxInterface)
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "Error processing network: ${e.message}")
                        continue
                    }
                }
            }

            cachedInterfaces = interfaces

        } catch (e: Exception) {
            Log.e(TAG, "Failed to build interface cache", e)
            cachedInterfaces = emptyList()
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): io.nekohasekai.libbox.NetworkInterfaceIterator {
        cachedInterfaces?.let {
            return InterfaceArray(ArrayList(it).iterator())
        }

        val interfaceList = try {
            val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = connectivityManager.allNetworks

            val networkInterfaces = try {
                NetworkInterface.getNetworkInterfaces().toList().toMutableList()
            } catch (e: Exception) {
                Log.e(TAG, "Error getting network interfaces in getInterfaces: ${e.message}")
                emptyList()
            }

            val interfaces = mutableListOf<LibboxNetworkInterface>()

            for (network in networks) {
                try {
                    val linkProperties = connectivityManager.getLinkProperties(network) ?: continue
                    val networkCapabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
                    val interfaceName = linkProperties.interfaceName ?: continue

                    if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) continue

                    val isPreferred = networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                                     networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

                    if (!isPreferred) continue

                    val networkInterface = networkInterfaces.find { it.name == interfaceName } ?: continue
                    val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                    interfaces.add(boxInterface)
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Error in interface loop: ${e.message}")
                    continue
                }
            }

            if (interfaces.isEmpty()) {
                for (network in networks) {
                    try {
                        val linkProperties = connectivityManager.getLinkProperties(network) ?: continue
                        val networkCapabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
                        val interfaceName = linkProperties.interfaceName ?: continue

                        if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) continue

                        if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                            val networkInterface = networkInterfaces.find { it.name == interfaceName } ?: continue
                            val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                            interfaces.add(boxInterface)
                            break
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in cellular fallback: ${e.message}")
                        continue
                    }
                }
            }

            val finalList = ArrayList(interfaces)
            cachedInterfaces = finalList
            finalList

        } catch (e: Exception) {
            Log.e(TAG, "Failed to get interfaces", e)
            ArrayList<LibboxNetworkInterface>()
        }

        return InterfaceArray(interfaceList.iterator())
    }

    private fun buildInterfaceInfo(
        interfaceName: String,
        networkInterface: NetworkInterface,
        networkCapabilities: NetworkCapabilities,
        linkProperties: android.net.LinkProperties
    ): LibboxNetworkInterface {
        val boxInterface = LibboxNetworkInterface()
        boxInterface.name = interfaceName
        boxInterface.index = networkInterface.index

        val dnsServers = linkProperties.dnsServers.mapNotNull { it.hostAddress }
        boxInterface.dnsServer = StringArray(ArrayList(dnsServers).iterator())

        boxInterface.type = when {
            networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
            networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
            networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
            else -> Libbox.InterfaceTypeOther
        }

        boxInterface.mtu = try {
            networkInterface.mtu
        } catch (e: Exception) {
            1500
        }

        val addresses = networkInterface.interfaceAddresses.mapNotNull { addr ->
            try {
                if (addr.address is Inet6Address) {
                    "${Inet6Address.getByAddress(addr.address.address).hostAddress}/${addr.networkPrefixLength}"
                } else {
                    "${addr.address.hostAddress}/${addr.networkPrefixLength}"
                }
            } catch (e: Exception) {
                null
            }
        }
        boxInterface.addresses = StringArray(ArrayList(addresses).iterator())

        var flags = 0
        if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        }
        if (networkInterface.isLoopback) {
            flags = flags or OsConstants.IFF_LOOPBACK
        }
        if (networkInterface.isPointToPoint) {
            flags = flags or OsConstants.IFF_POINTOPOINT
        }
        if (networkInterface.supportsMulticast()) {
            flags = flags or OsConstants.IFF_MULTICAST
        }
        boxInterface.flags = flags

        boxInterface.metered = !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)

        return boxInterface
    }

    private class InterfaceArray(private val iterator: Iterator<LibboxNetworkInterface>) :
        io.nekohasekai.libbox.NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): LibboxNetworkInterface = iterator.next()
    }

    private class StringArray(private val iterator: Iterator<String>) : StringIterator {
        override fun len(): Int = 0
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): String = iterator.next()
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}
    override fun readWIFIState(): io.nekohasekai.libbox.WIFIState? = null
    override fun systemCertificates(): io.nekohasekai.libbox.StringIterator =
        object : io.nekohasekai.libbox.StringIterator {
            override fun len(): Int = 0
            override fun hasNext(): Boolean = false
            override fun next(): String? = null
        }
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {}

    private fun setVpnState(running: Boolean) {
        synchronized(prefsLock) {
            prefs.edit().putBoolean(KEY_IS_RUNNING, running).apply()
        }
        Log.d(TAG, "✅ VPN state set to: $running")
    }

    fun getVpnState(): Boolean {
        synchronized(prefsLock) {
            return prefs.getBoolean(KEY_IS_RUNNING, false)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN Service",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "VPN connection status"
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                setBypassDnd(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(title: String, message: String): Notification {
        val stopIntent = Intent(this, MyVpnService::class.java).apply {
            action = "STOP_VPN"
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Disconnect",
                stopPendingIntent
            )
            .setDeleteIntent(stopPendingIntent)
            .setGroup("vpn_services")
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
            .build()
    }

    private fun areNotificationsEnabled(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = manager.getNotificationChannel(CHANNEL_ID)
            return channel?.importance != NotificationManager.IMPORTANCE_NONE
        }
        return true
    }

    private suspend fun cleanupVpn(reason: String) {
        VpnLogger.log(TAG, "🧹 Starting VPN cleanup (reason: $reason)")

        try {
            // Stop heartbeat first
            stopHeartbeatMonitoring()

            // Close services in correct order: box first, then the command server.
            closeCommandServer()

            // ⭐ CRITICAL: Wait for port 9090 to be fully released
            delay(500)
            VpnLogger.log(TAG, "✅ Port release delay complete")

            // Close file descriptor
            fileDescriptor?.let { fd ->
                try {
                    VpnLogger.log(TAG, "Closing fileDescriptor...")
                    fd.close()
                    VpnLogger.log(TAG, "✅ fileDescriptor closed")
                } catch (e: Exception) {
                    VpnLogger.error(TAG, "Error closing fileDescriptor", e)
                }
            }
            fileDescriptor = null

            VpnLogger.log(TAG, "✅ VPN cleanup complete")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Error during VPN cleanup", e)
        }
    }

    // ✅ NEW: Start watchdog service in separate process
    private fun startWatchdogService() {
        try {
            val intent = Intent(this, VpnWatchdogService::class.java).apply {
                // ✅ AJOUTE: Passe le contenu de la notification actuelle
                putExtra("notification_title", "Vulcain VPN")
                putExtra("notification_text", "Connected")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }

            VpnLogger.log(TAG, "✅ Watchdog service started")
            Log.d(TAG, "✅ VPN watchdog service started")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to start watchdog", e)
            Log.e(TAG, "Failed to start watchdog: ${e.message}")
        }
    }

    private fun showErrorNotification(message: String) {
        try {
            val notificationManager = getSystemService(NotificationManager::class.java)

            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("VPN Error")
                .setContentText(message)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            notificationManager.notify(8888, notification)
        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to show error notification", e)
        }
    }

    private fun stopWatchdogService() {
        try {
            val intent = Intent(this, VpnWatchdogService::class.java)
            stopService(intent)

            VpnLogger.log(TAG, "✅ Watchdog service stopped")
            Log.d(TAG, "✅ VPN watchdog service stopped")

        } catch (e: Exception) {
            VpnLogger.error(TAG, "Failed to stop watchdog", e)
            Log.e(TAG, "Failed to stop watchdog: ${e.message}")
        }
    }
}
