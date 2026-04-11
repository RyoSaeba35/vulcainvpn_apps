package com.example.cross_platform_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.BoxService as LibboxService
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

class MyVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "MyVpnService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "vpn_channel"

        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val KEY_START_TIME = "start_time"
        private const val KEY_LAST_SEEN_AT = "last_seen_at"

        private const val HEARTBEAT_INTERVAL_MS = 10000L
        private const val HEARTBEAT_TIMEOUT_MS = 3000
        private const val MAX_CONSECUTIVE_FAILURES = 3
    }

    private var boxService: LibboxService? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var cachedInterfaces: List<LibboxNetworkInterface>? = null
    private var cachedConfig: String? = null
    private var cachedAccessToken: String? = null  // ← NEW!

    private var isNormalStop = false
    private var deathEventSent = false

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var heartbeatJob: Job? = null

    private var consecutiveFailures = 0
    private var lastSuccessfulPing: Long = 0

    private val isServiceAlive = AtomicBoolean(true)

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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "STOP_VPN" -> {
                isNormalStop = true
                stopVpnService()
                return START_NOT_STICKY
            }
            else -> {
                if (!areNotificationsEnabled()) {
                    Log.e(TAG, "Notifications are disabled!")
                    stopSelf()
                    return START_NOT_STICKY
                }

                val notification = createNotification("Vulcain VPN", "Connecting...")
                startForeground(NOTIFICATION_ID, notification)
                Log.d(TAG, "✅ Started foreground immediately")

                intent?.getStringExtra("VPN_CONFIG")?.let { config ->
                    cachedConfig = config
                }

                // ✅ NEW: Get access token from intent
                intent?.getStringExtra("ACCESS_TOKEN")?.let { token ->
                    cachedAccessToken = token
                }

                if (!getVpnState()) startVpnService()
                return START_STICKY
            }
        }
    }

    private fun startVpnService() {
        VpnLogger.log(TAG, "🟢 Starting VPN service")
        VpnLogger.markCrashScenario("VPN_START")
        Log.d(TAG, "Starting VPN service")

        isNormalStop = false
        deathEventSent = false
        consecutiveFailures = 0
        lastSuccessfulPing = System.currentTimeMillis()

        synchronized(prefsLock) {
            prefs.edit().putLong(KEY_LAST_SEEN_AT, System.currentTimeMillis()).apply()
        }

        Thread {
            try {
                VpnLogger.log(TAG, "🔐 Checking subscription status...")

                // ✅ CRITICAL FIX: Use passed token, not storage
                val token = cachedAccessToken ?: getSecureValue("access_token")

                if (token == null) {
                    VpnLogger.log(TAG, "❌ No access token available")
                    notifyFlutterVpnDeath("auth_required", "Authentication required")
                    mainHandler.post { stopSelf() }
                    return@Thread
                }

                val subscriptionStatus = runBlocking {
                    checkSubscription(token)  // ← Pass token explicitly
                }
                VpnLogger.log(TAG, "Subscription status: $subscriptionStatus")

                when (subscriptionStatus) {
                    "expired", "canceled" -> {
                        VpnLogger.log(TAG, "❌ Subscription not active ($subscriptionStatus)")
                        VpnLogger.log(TAG, "Stopping VPN start - sending subscription_expired death event")

                        setVpnState(false)
                        notifyFlutterVpnDeath("subscription_expired", "Your VPN subscription has expired")

                        mainHandler.post {
                            stopSelf()
                        }
                        return@Thread
                    }
                    "auth_failed" -> {
                        // ✅ NEW: Token is invalid - tell Flutter
                        VpnLogger.log(TAG, "❌ Authentication failed - token invalid")
                        setVpnState(false)
                        notifyFlutterVpnDeath("auth_required", "Session expired - please login again")
                        mainHandler.post { stopSelf() }
                        return@Thread
                    }
                    "active" -> {
                        VpnLogger.log(TAG, "✅ Subscription is active - proceeding with VPN start")
                    }
                    else -> {
                        VpnLogger.log(TAG, "⚠️ Subscription status unknown - proceeding with caution")
                    }
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

                VpnLogger.log(TAG, "🚀 Creating libbox service...")
                Libbox.setMemoryLimit(true)
                val service = Libbox.newService(config, this)
                VpnLogger.log(TAG, "✅ Libbox service created, starting...")

                service.start()
                boxService = service
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

                startHeartbeatMonitoring()

            } catch (e: Exception) {
                VpnLogger.error(TAG, "❌ VPN START FAILED", e)
                Log.e(TAG, "❌ Failed to start VPN", e)
                setVpnState(false)
                notifyFlutterVpnState("error", "Failed to start: ${e.message}")
                stopSelf()
            }
        }.start()
    }

    // ✅ UPDATED: Accept token parameter
    private suspend fun checkSubscription(accessToken: String): String {
        return withContext(Dispatchers.IO) {
            try {
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
                        VpnLogger.log(TAG, "⚠️ Authentication failed ($responseCode) - token invalid")
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

    private fun getConfig(): String {
        cachedConfig?.let { return it }
        return try {
            assets.open("config.json").bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load config", e)
            throw IllegalStateException("No config available")
        }
    }

    private fun startHeartbeatMonitoring() {
        stopHeartbeatMonitoring()
        Log.d(TAG, "💓 Starting heartbeat monitoring (every ${HEARTBEAT_INTERVAL_MS/1000}s)")

        heartbeatJob = serviceScope.launch(Dispatchers.IO) {
            while (isActive && getVpnState() && isServiceAlive.get()) {
                delay(HEARTBEAT_INTERVAL_MS)

                if (!isServiceAlive.get()) {
                    Log.d(TAG, "💓 Heartbeat stopped - service destroyed")
                    break
                }

                try {
                    val isReachable = performHeartbeatCheck()

                    if (isReachable) {
                        if (consecutiveFailures > 0) {
                            Log.d(TAG, "💚 Heartbeat recovered after $consecutiveFailures failures")
                        }
                        consecutiveFailures = 0
                        lastSuccessfulPing = System.currentTimeMillis()

                        synchronized(prefsLock) {
                            prefs.edit().putLong(KEY_LAST_SEEN_AT, System.currentTimeMillis()).apply()
                        }
                    } else {
                        consecutiveFailures++
                        val timeSinceLastSuccess = (System.currentTimeMillis() - lastSuccessfulPing) / 1000

                        Log.w(TAG, "💔 Heartbeat failed ($consecutiveFailures/$MAX_CONSECUTIVE_FAILURES) - Last success: ${timeSinceLastSuccess}s ago")

                        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
                            handleHeartbeatFailure()
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Heartbeat check error: ${e.message}")
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
    }

    private suspend fun performHeartbeatCheck(): Boolean {
        if (!isServiceAlive.get()) {
            Log.w(TAG, "performHeartbeatCheck called on destroyed service")
            return false
        }

        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            try {
                val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

                val underlyingNetwork = connectivityManager.allNetworks.firstOrNull { network ->
                    val caps = connectivityManager.getNetworkCapabilities(network)
                    caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                }

                if (underlyingNetwork == null) {
                    return@withContext false
                }

                socket = java.net.Socket()
                protect(socket)

                try {
                    underlyingNetwork.bindSocket(socket)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to bind socket: ${e.message}")
                }

                socket.connect(
                    java.net.InetSocketAddress("api.vulcainvpn.com", 443),
                    HEARTBEAT_TIMEOUT_MS
                )

                true
            } catch (e: Exception) {
                false
            } finally {
                try {
                    socket?.close()
                } catch (e: Exception) {
                    // Ignore close errors
                }
            }
        }
    }

    private suspend fun handleHeartbeatFailure() {
        VpnLogger.critical(TAG, "🚨 HEARTBEAT FAILURE DETECTED")
        VpnLogger.markCrashScenario("HEARTBEAT_FAILURE")

        if (!isServiceAlive.get()) {
            Log.w(TAG, "handleHeartbeatFailure called on destroyed service")
            return
        }

        withContext(Dispatchers.Main) {
            Log.e(TAG, "🚨 HEARTBEAT FAILURE DETECTED!")

            // ✅ SIMPLIFIED: Check if network exists (for logging/reason only)
            val hasAnyNetwork = withContext(Dispatchers.IO) {
                try {
                    if (!isServiceAlive.get()) return@withContext false

                    val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                    val activeNetwork = connectivityManager.activeNetwork ?: return@withContext false
                    val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                    val hasWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    val hasCellular = caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
                    val hasEthernet = caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
                    hasWifi || hasCellular || hasEthernet
                } catch (e: Exception) {
                    false
                }
            }

            if (!hasAnyNetwork) {
                Log.w(TAG, "📶 NO UNDERLYING NETWORK DETECTED (airplane mode?)")
                VpnLogger.log(TAG, "⏳ No network - broadcasting 'network_lost'")
            } else {
                Log.e(TAG, "🔴 VPN IS BROKEN (network exists but heartbeat fails)")
                VpnLogger.log(TAG, "🔴 Network exists - broadcasting 'vpn_broken'")
            }

            // ✅ CRITICAL CHANGE: ALWAYS broadcast immediately (Option 1)
            // Let AutoReconnectService decide what to do based on network state
            if (!isServiceAlive.get()) return@withContext

            VpnLogger.log(TAG, "🔴 Stopping service and triggering auto-reconnect")

            isNormalStop = false
            deathEventSent = true

            stopHeartbeatMonitoring()

            try {
                boxService?.close()
                boxService = null
                fileDescriptor?.close()
                fileDescriptor = null
            } catch (e: Exception) {
                Log.e(TAG, "Error closing VPN: ${e.message}")
            }

            setVpnState(false)

            // Send broadcast with appropriate reason
            val reason = if (hasAnyNetwork) "vpn_broken" else "network_lost"
            notifyFlutterVpnDeath(reason, "VPN connection lost. Please reconnect.")

            Thread.sleep(300)
            stopSelf()
            consecutiveFailures = 0
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
            boxService?.close()
            boxService = null

            setVpnState(false)

            synchronized(prefsLock) {
                prefs.edit().remove(KEY_START_TIME).apply()
            }

            if (isNormalStop) {
                notifyFlutterVpnState("disconnected", "VPN disconnected by user")
            } else {
                notifyFlutterVpnState("died", "VPN stopped unexpectedly")
            }

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

        if (!isNormalStop && !deathEventSent) {
            Log.e(TAG, "⚠️ VPN SERVICE KILLED UNEXPECTEDLY BY ANDROID!")
            notifyFlutterVpnDeath("service_killed", "Android killed VPN service (low memory or system cleanup)")
        }

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
            builder.addDnsServer(options.dnsServerAddress.value)
            builder.addRoute("0.0.0.0", 0)
        }

        val pfd = builder.establish() ?: throw Exception("Failed to establish VPN")
        fileDescriptor = pfd
        Log.d(TAG, "✅ TUN established")
        return pfd.fd
    }

    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport? = null
    override fun writeLog(message: String) {
        if (!message.contains("http2: client connection force closed") &&
            !message.contains("operation was canceled")) {
            Log.d(TAG, "libbox: $message")
        }
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): Int = -1
    override fun packageNameByUid(uid: Int): String = packageManager.getPackagesForUid(uid)?.first() ?: "unknown"
    override fun uidByPackageName(packageName: String): Int =
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                packageManager.getPackageUid(packageName, PackageManager.PackageInfoFlags.of(0))
            else
                @Suppress("DEPRECATION") packageManager.getApplicationInfo(packageName, 0).uid
        } catch (_: PackageManager.NameNotFoundException) { -1 }

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
            .setSmallIcon(android.R.drawable.ic_dialog_info)
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
}
