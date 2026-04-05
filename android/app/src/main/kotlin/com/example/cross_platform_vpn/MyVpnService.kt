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

class MyVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "MyVpnService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "vpn_channel"

        // SharedPreferences keys
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val KEY_START_TIME = "start_time"

        // ✅ PRIORITY 2: Heartbeat constants
        private const val HEARTBEAT_INTERVAL_MS = 10000L // 10 seconds
        private const val HEARTBEAT_TIMEOUT_MS = 3000 // 3 seconds per ping
        private const val MAX_CONSECUTIVE_FAILURES = 3 // 30 seconds total before alert
    }

    private var boxService: LibboxService? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cache for interface list to prevent recursive calls
    private var cachedInterfaces: List<LibboxNetworkInterface>? = null
    private var cachedConfig: String? = null

    // ✅ PRIORITY 1: Track if this is a normal stop or unexpected death
    private var isNormalStop = false

    // ✅ PRIORITY 2: Heartbeat monitoring
    private var heartbeatJob: Job? = null
    private var consecutiveFailures = 0
    private var lastSuccessfulPing: Long = 0

    // ✅ NEW: Network recovery tracking for airplane mode fix
    private var wasNetworkLost = false
    private var networkLostTimestamp: Long = 0

    private val prefs: SharedPreferences by lazy {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")
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
                intent?.getStringExtra("VPN_CONFIG")?.let { config ->
                    cachedConfig = config
                }
                if (!getVpnState()) startVpnService()
                return START_STICKY
            }
        }
    }

    private fun startVpnService() {
        Log.d(TAG, "Starting VPN service")

        isNormalStop = false
        consecutiveFailures = 0
        lastSuccessfulPing = System.currentTimeMillis()
        wasNetworkLost = false  // ✅ NEW: Reset network loss flag

        if (!areNotificationsEnabled()) {
            Log.e(TAG, "Notifications are disabled!")
            stopSelf()
            return
        }

        val notification = createNotification("Vulcain VPN", "Connected")
        startForeground(NOTIFICATION_ID, notification)

        Thread {
            try {
                val config = getConfig()
                val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

                runBlocking {
                    DefaultNetworkMonitor.start(connectivityManager)
                }

                Libbox.setMemoryLimit(true)
                val service = Libbox.newService(config, this)
                service.start()
                boxService = service

                setVpnState(true)
                prefs.edit().putLong(KEY_START_TIME, System.currentTimeMillis()).apply()

                notifyFlutterVpnState("connected", "VPN connected successfully")
                Log.d(TAG, "✅ VPN started successfully")

                startHeartbeatMonitoring()

            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to start VPN", e)
                notifyFlutterVpnState("error", "Failed to start: ${e.message}")
                stopSelf()
            }
        }.start()
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

    // ✅ PRIORITY 2: Start heartbeat monitoring
    private fun startHeartbeatMonitoring() {
        stopHeartbeatMonitoring()
        Log.d(TAG, "💓 Starting heartbeat monitoring (every ${HEARTBEAT_INTERVAL_MS/1000}s)")

        heartbeatJob = CoroutineScope(Dispatchers.IO).launch {
            while (isActive && getVpnState()) {
                delay(HEARTBEAT_INTERVAL_MS)

                try {
                    val isReachable = performHeartbeatCheck()

                    if (isReachable) {
                        if (consecutiveFailures > 0) {
                            Log.d(TAG, "💚 Heartbeat recovered after $consecutiveFailures failures")
                        }
                        consecutiveFailures = 0
                        lastSuccessfulPing = System.currentTimeMillis()
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
        heartbeatJob?.cancel()
        heartbeatJob = null
        consecutiveFailures = 0
    }

    // ✅ UPDATED: Enhanced heartbeat check with network recovery detection
    private suspend fun performHeartbeatCheck(): Boolean {
        return withContext(Dispatchers.IO) {
            var socket: java.net.Socket? = null
            try {
                socket = java.net.Socket()
                socket.connect(
                    java.net.InetSocketAddress("api.vulcainvpn.com", 443),
                    HEARTBEAT_TIMEOUT_MS
                )

                // ✅ NEW: Check if network just recovered
                if (wasNetworkLost) {
                    val downtime = System.currentTimeMillis() - networkLostTimestamp
                    Log.d(TAG, "🔄 NETWORK RECOVERED after ${downtime / 1000}s!")
                    Log.d(TAG, "   Attempting to restart VPN tunnel...")

                    // Trigger VPN restart on main thread
                    mainHandler.post {
                        handleNetworkRecovery()
                    }

                    wasNetworkLost = false
                }

                true
            } catch (e: Exception) {
                false
            } finally {
                socket?.close()
            }
        }
    }

    // ✅ UPDATED: Enhanced heartbeat failure handler with network loss tracking
    private suspend fun handleHeartbeatFailure() {
        withContext(Dispatchers.Main) {
            Log.e(TAG, "🚨 HEARTBEAT FAILURE DETECTED!")
            Log.e(TAG, "   VPN is connected but no internet access through VPN")
            Log.e(TAG, "   3 consecutive ping failures detected")

            // ✅ Check if device has ANY network at all
            val hasAnyNetwork = withContext(Dispatchers.IO) {
                try {
                    val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                    val activeNetwork = connectivityManager.activeNetwork ?: return@withContext false

                    val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
                    val hasWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                    val hasCellular = caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
                    val hasEthernet = caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true

                    Log.d(TAG, "   Network check: WiFi=$hasWifi, Cellular=$hasCellular, Ethernet=$hasEthernet")
                    hasWifi || hasCellular || hasEthernet
                } catch (e: Exception) {
                    Log.e(TAG, "   Error checking network: ${e.message}")
                    false
                }
            }

            if (!hasAnyNetwork) {
                // ✅ SCENARIO: NO NETWORK (airplane mode, out of range, etc.)
                Log.w(TAG, "📶 NO UNDERLYING NETWORK DETECTED")
                Log.w(TAG, "   Keeping VPN connected - will resume when network returns")

                // ✅ NEW: Track that network was lost
                if (!wasNetworkLost) {
                    wasNetworkLost = true
                    networkLostTimestamp = System.currentTimeMillis()
                    Log.d(TAG, "   📍 Marking network as lost at ${networkLostTimestamp}")
                }

                consecutiveFailures = 0  // Reset counter
                return@withContext
            }

            // ✅ SCENARIO: VPN BROKEN (server down, credentials expired, etc.)
            Log.e(TAG, "🔴 VPN IS BROKEN")
            Log.e(TAG, "   ✅ Device has active network")
            Log.e(TAG, "   ❌ VPN tunnel is not working")
            Log.e(TAG, "   → Stopping VPN and notifying user")

            // Reset network lost flag
            wasNetworkLost = false

            isNormalStop = true
            notifyFlutterVpnDeath("vpn_broken", "VPN connection lost. Please reconnect.")
            stopVpnService()
            consecutiveFailures = 0
        }
    }

    // ✅ NEW: Handle network recovery by restarting VPN tunnel
    private fun handleNetworkRecovery() {
        Log.d(TAG, "🔄 Starting VPN recovery process...")

        Thread {
            try {
                // Step 1: Stop current VPN instance cleanly
                Log.d(TAG, "   Step 1: Stopping current VPN instance...")
                isNormalStop = true  // Prevent death broadcast

                // Close sing-box service
                boxService?.close()
                boxService = null

                // Close TUN interface
                fileDescriptor?.close()
                fileDescriptor = null

                // Step 2: Small delay to ensure cleanup
                Log.d(TAG, "   Step 2: Waiting for cleanup...")
                Thread.sleep(1000)

                // Step 3: Get config
                Log.d(TAG, "   Step 3: Loading config...")
                val config = getConfig()
                if (config.isEmpty()) {
                    throw Exception("No config available for recovery")
                }

                // Step 4: Restart VPN with existing config
                Log.d(TAG, "   Step 4: Restarting VPN service...")
                isNormalStop = false
                consecutiveFailures = 0
                lastSuccessfulPing = System.currentTimeMillis()

                val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

                runBlocking {
                    DefaultNetworkMonitor.start(connectivityManager)
                }

                Libbox.setMemoryLimit(true)
                val service = Libbox.newService(config, this)
                service.start()
                boxService = service

                Log.d(TAG, "✅ VPN successfully restarted after network recovery")

                // Notify Flutter
                notifyFlutterVpnState("connected", "VPN reconnected after network recovery")

            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to restart VPN after network recovery", e)

                // If restart fails, send death event
                isNormalStop = false
                wasNetworkLost = false

                notifyFlutterVpnDeath(
                    "vpn_broken",
                    "Failed to recover VPN after network change: ${e.message}"
                )

                // Stop service
                mainHandler.post {
                    stopSelf()
                }
            }
        }.start()
    }

    // ✅ FOR FUTURE USE: Check subscription before reconnect (Priority 3)
    // This method is ready but NOT called during VPN death (DNS doesn't work)
    // Call this from Flutter BEFORE reconnecting in Priority 3
    suspend fun checkSubscriptionWithProtectedSocket(): String {
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
                val protected = protect(socket)

                if (!protected) {
                    try {
                        underlyingNetwork.bindSocket(socket)
                    } catch (e: Exception) {
                        // Continue anyway
                    }
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
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )

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
                DefaultNetworkMonitor.stop()
            }
            cachedConfig = null
            cachedInterfaces = null
            fileDescriptor?.close()
            fileDescriptor = null
            boxService?.close()
            boxService = null

            setVpnState(false)
            prefs.edit().remove(KEY_START_TIME).apply()

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

    // ✅ PRIORITY 1: Enhanced onDestroy - detects unexpected deaths
    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "🔴 Service destroyed (normal stop: $isNormalStop)")

        stopHeartbeatMonitoring()
        setVpnState(false)
        prefs.edit().remove(KEY_START_TIME).apply()

        if (!isNormalStop) {
            Log.e(TAG, "⚠️ VPN SERVICE KILLED UNEXPECTEDLY BY ANDROID!")
            notifyFlutterVpnDeath("service_killed", "Android killed VPN service (low memory or system cleanup)")
        }
    }

    // ✅ PRIORITY 1: Enhanced onRevoke - permission was revoked
    override fun onRevoke() {
        super.onRevoke()
        Log.e(TAG, "🔴 VPN PERMISSION REVOKED!")

        isNormalStop = false
        notifyFlutterVpnDeath("permission_revoked", "VPN permission was revoked")
        stopVpnService()
    }

    // ✅ PRIORITY 1: Notify Flutter of VPN death
    private fun notifyFlutterVpnDeath(reason: String, message: String) {
        Log.e(TAG, "💀 VPN DIED: reason=$reason, message=$message")

        mainHandler.post {
            MainActivity.statusSink?.success(mapOf(
                "event" to "vpn_died",
                "reason" to reason,
                "message" to message,
                "timestamp" to System.currentTimeMillis()
            ))
        }

        try {
            val intent = Intent("com.vulcain.vpn.VPN_DIED").apply {
                putExtra("reason", reason)
                putExtra("message", message)
                putExtra("timestamp", System.currentTimeMillis())
                setPackage(packageName)
            }
            sendBroadcast(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send broadcast", e)
        }
    }

    private fun notifyFlutterVpnState(event: String, message: String) {
        mainHandler.post {
            MainActivity.statusSink?.success(mapOf(
                "event" to event,
                "message" to message,
                "timestamp" to System.currentTimeMillis()
            ))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    // =============================
    // PlatformInterface Implementation
    // =============================

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        try {
            protect(fd)
        } catch (e: Exception) {
            // Silent - happens frequently during normal operation
        }
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
        // Filter out noisy libbox errors
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
            val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
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
                    val linkProperties = connectivityManager.getLinkProperties(n) ?: continue
                    val networkCapabilities = connectivityManager.getNetworkCapabilities(n) ?: continue
                    val interfaceName = linkProperties.interfaceName ?: continue

                    if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) continue

                    val networkInterface = networkInterfaces.find { it.name == interfaceName } ?: continue
                    val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                    interfaces.add(boxInterface)
                    break
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
            val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
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

    // =============================
    // STATE PERSISTENCE
    // =============================

    private fun setVpnState(running: Boolean) {
        prefs.edit().putBoolean(KEY_IS_RUNNING, running).apply()
    }

    fun getVpnState(): Boolean {
        return prefs.getBoolean(KEY_IS_RUNNING, false)
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
