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
import kotlinx.coroutines.*
import java.net.HttpURLConnection
import java.net.URL
import android.content.Context
import android.content.SharedPreferences

class MyVpnService : VpnService(), PlatformInterface {

    companion object {
        private const val TAG = "MyVpnService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "vpn_channel"

        // ⭐ CHANGED: Use SharedPreferences instead of static variable
        private const val PREFS_NAME = "vpn_state"
        private const val KEY_IS_RUNNING = "is_running"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_API_KEY = "api_key"

        var isRunning: Boolean
            get() = false // Deprecated - use SharedPreferences instead
            set(_) {} // Deprecated
    }

    private var boxService: LibboxService? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cache for interface list to prevent recursive calls
    private var cachedInterfaces: List<LibboxNetworkInterface>? = null

    // ⭐ NEW: Heartbeat coroutine job
    private var heartbeatJob: Job? = null
    private val heartbeatScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // ⭐ NEW: SharedPreferences
    private val prefs: SharedPreferences by lazy {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}")

        when (intent?.action) {
            "STOP_VPN" -> {
                stopVpnService()
                return START_NOT_STICKY
            }
            else -> {
                // ⭐ Get config from intent
                intent?.getStringExtra("VPN_CONFIG")?.let { config ->
                    Log.d(TAG, "Received config from Flutter (${config.length} chars)")
                    cachedConfig = config
                }

                // ⭐ Store device credentials for heartbeat
                intent?.getStringExtra("DEVICE_ID")?.let { deviceId ->
                    prefs.edit().putString(KEY_DEVICE_ID, deviceId).apply()
                    Log.d(TAG, "Stored device_id: $deviceId")
                }
                intent?.getStringExtra("API_KEY")?.let { apiKey ->
                    prefs.edit().putString(KEY_API_KEY, apiKey).apply()
                    Log.d(TAG, "Stored api_key: ${apiKey.take(20)}...")
                }

                if (!getVpnState()) startVpnService()  // ⭐ CHANGED: use getVpnState() instead of isRunning
                return START_STICKY
            }
        }
    }

    private fun startVpnService() {
        Log.d(TAG, "Starting VPN service")

        if (!areNotificationsEnabled()) {
            Log.e(TAG, "Notifications are disabled!")
            stopSelf()
            return
        }
        val notification = createNotification("Vulcain VPN", "Connected")
        startForeground(NOTIFICATION_ID, notification)

        Thread {
            try {
                val config = getConfig()  // ⭐ Changed from loadConfigFromAssets()

                Log.d(TAG, "Starting sing-box service")

                val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

                runBlocking {
                    DefaultNetworkMonitor.start(connectivityManager)
                }

                Libbox.setMemoryLimit(true)
                val service = Libbox.newService(config, this)
                service.start()

                boxService = service

                // ⭐ Save state to SharedPreferences
                setVpnState(true)

                MainActivity.statusSink?.success(true)
                Log.d(TAG, "✅ VPN started successfully")

                // ⭐ START HEARTBEAT
                startHeartbeat()

            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to start VPN", e)
                stopSelf()
            }
        }.start()
    }

    private var cachedConfig: String? = null

    private fun getConfig(): String {
        // Return cached config if available
        cachedConfig?.let {
            Log.d(TAG, "Using cached config")
            return it
        }

        // Fallback: try to load from assets (for backward compatibility)
        return try {
            val config = assets.open("config.json").bufferedReader().use { it.readText() }
            Log.d(TAG, "Loaded config from assets (fallback)")
            config
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load config", e)
            throw IllegalStateException("No config available")
        }
    }

    private fun stopVpnService() {
        Log.d(TAG, "Stopping VPN service")

        // ⭐ STOP HEARTBEAT FIRST
        stopHeartbeat()

        try {
            runBlocking {
                DefaultNetworkMonitor.stop()
            }
            cachedConfig = null  // ⭐ Clear cached config
            cachedInterfaces = null
            fileDescriptor?.close()
            fileDescriptor = null
            boxService?.close()
            boxService = null

            // ⭐ Save state to SharedPreferences
            setVpnState(false)

            MainActivity.statusSink?.success(false)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Service destroyed")

        // ⭐ Stop heartbeat
        stopHeartbeat()

        // ⭐ Only clear state if we explicitly stopped
        if (boxService == null) {
            setVpnState(false)
        }

        MainActivity.statusSink?.success(false)
    }

    override fun onRevoke() {
        super.onRevoke()
        Log.d(TAG, "VPN permission revoked")
        stopVpnService()
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    // =============================
    // PlatformInterface Implementation
    // =============================

    override fun usePlatformAutoDetectInterfaceControl(): Boolean {
        Log.d(TAG, "⚙️ usePlatformAutoDetectInterfaceControl() called, returning TRUE")
        return true
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        try {
            val result = protect(fd)
            Log.d(TAG, "🛡️ PROTECT: fd=$fd result=$result")
        } catch (e: Exception) {
            Log.e(TAG, "❌ PROTECT FAILED: fd=$fd", e)
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

        // IPv4
        val inet4 = options.inet4Address
        while (inet4.hasNext()) {
            val addr = inet4.next()
            builder.addAddress(addr.address(), addr.prefix().toInt())
            Log.d(TAG, "Added IPv4: ${addr.address()}/${addr.prefix()}")
        }

        // IPv6
        val inet6 = options.inet6Address
        while (inet6.hasNext()) {
            val addr = inet6.next()
            builder.addAddress(addr.address(), addr.prefix().toInt())
            Log.d(TAG, "Added IPv6: ${addr.address()}/${addr.prefix()}")
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)
            builder.addRoute("0.0.0.0", 0)
            Log.d(TAG, "Added route: 0.0.0.0/0, DNS: ${options.dnsServerAddress.value}")
        }

        try {
            val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val linkProps = connectivityManager.getLinkProperties(connectivityManager.activeNetwork)
            val interfaceName = linkProps?.interfaceName
            Log.d(TAG, "📡 Active network interface: $interfaceName")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get network interface name", e)
        }

        val pfd = builder.establish() ?: throw Exception("Failed to establish VPN")
        fileDescriptor = pfd
        Log.d(TAG, "✅ TUN established with fd: ${pfd.fd}")
        return pfd.fd
    }

    override fun localDNSTransport(): io.nekohasekai.libbox.LocalDNSTransport? = null

    override fun writeLog(message: String) { Log.d(TAG, "libbox: $message") }
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
        Log.d(TAG, "🔍 startDefaultInterfaceMonitor() called")

        // Register callback to pre-cache interfaces BEFORE sing-box gets notified
        DefaultNetworkMonitor.onInterfaceCacheRequest = { network ->
            Log.d(TAG, "📦 Building interface cache for network: $network")
            // Call buildInterfaces() to build the cache
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

            // Priority 1: Use the specific network we were given
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
                        Log.d(TAG, "✅ Cached active network interface: $interfaceName type=${boxInterface.type}")
                    }
                }
            }

            // Priority 2: Fallback - scan all networks if active network gave nothing
            if (interfaces.isEmpty()) {
                Log.w(TAG, "⚠️ Active network gave no interface, scanning all networks as fallback")
                for (n in connectivityManager.allNetworks) {
                    val linkProperties = connectivityManager.getLinkProperties(n) ?: continue
                    val networkCapabilities = connectivityManager.getNetworkCapabilities(n) ?: continue
                    val interfaceName = linkProperties.interfaceName ?: continue

                    if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) continue

                    val networkInterface = networkInterfaces.find { it.name == interfaceName } ?: continue
                    val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                    interfaces.add(boxInterface)
                    Log.d(TAG, "✅ Fallback interface: $interfaceName type=${boxInterface.type}")
                    break
                }
            }

            cachedInterfaces = interfaces
            Log.d(TAG, "✅ Interface cache built: ${interfaces.size} interfaces")

        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to build interface cache", e)
            cachedInterfaces = emptyList()
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        Log.d(TAG, "🔍 closeDefaultInterfaceMonitor() called")
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): io.nekohasekai.libbox.NetworkInterfaceIterator {
        // If we have cached interfaces, return them immediately (prevents recursive callback)
        cachedInterfaces?.let {
            Log.d(TAG, "🔍 getInterfaces() called, returning ${it.size} cached interfaces")
            return InterfaceArray(ArrayList(it).iterator())
        }

        // Build the interface list for the first time
        val interfaceList = try {
            val connectivityManager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = connectivityManager.allNetworks
            val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
            val interfaces = mutableListOf<LibboxNetworkInterface>()

            Log.d(TAG, "🔍 getInterfaces() called, scanning ${networks.size} networks")

            // First pass: Find WiFi or Ethernet (preferred)
            for (network in networks) {
                try {
                    val linkProperties = connectivityManager.getLinkProperties(network) ?: continue
                    val networkCapabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
                    val interfaceName = linkProperties.interfaceName ?: continue

                    // Skip VPN interfaces
                    if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) {
                        Log.d(TAG, "⏭️ Skipping VPN interface: $interfaceName")
                        continue
                    }

                    // Only WiFi or Ethernet
                    val isPreferred = networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                                     networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

                    if (!isPreferred) continue

                    val networkInterface = networkInterfaces.find { it.name == interfaceName }
                    if (networkInterface == null) {
                        Log.w(TAG, "⚠️ NetworkInterface not found for: $interfaceName")
                        continue
                    }

                    val boxInterface = buildInterfaceInfo(interfaceName, networkInterface, networkCapabilities, linkProperties)
                    interfaces.add(boxInterface)
                    Log.d(TAG, "✅ Added preferred interface: $interfaceName, type=${boxInterface.type}, index=${boxInterface.index}")
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing network interface", e)
                    continue
                }
            }

            // Second pass: Mobile data fallback
            if (interfaces.isEmpty()) {
                Log.d(TAG, "No WiFi/Ethernet found, looking for mobile data...")
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
                            Log.d(TAG, "✅ Added fallback interface (mobile): $interfaceName, type=${boxInterface.type}, index=${boxInterface.index}")
                            break
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error processing fallback interface", e)
                        continue
                    }
                }
            }

            Log.d(TAG, "✅ getInterfaces() built and cached ${interfaces.size} interfaces")

            // Cache the list
            val finalList = ArrayList(interfaces)
            cachedInterfaces = finalList
            finalList

        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to get interfaces", e)
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
    // ⭐ HEARTBEAT IMPLEMENTATION
    // =============================

    private fun startHeartbeat() {
        stopHeartbeat() // Clear any existing job

        val deviceId = prefs.getString(KEY_DEVICE_ID, null)
        val apiKey = prefs.getString(KEY_API_KEY, null)

        if (deviceId == null || apiKey == null) {
            Log.w(TAG, "⚠️  Cannot start heartbeat: missing credentials")
            return
        }

        Log.d(TAG, "🟢 Starting heartbeat timer (every 90s)")

        heartbeatJob = heartbeatScope.launch {
            while (isActive) {
                try {
                    sendHeartbeat(deviceId, apiKey)
                    delay(90_000) // 90 seconds
                } catch (e: CancellationException) {
                    Log.d(TAG, "Heartbeat job cancelled")
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "⚠️  Heartbeat error: ${e.message}")
                    delay(90_000) // Continue trying even if one fails
                }
            }
        }

        // Send first heartbeat immediately
        heartbeatScope.launch {
            try {
                sendHeartbeat(deviceId, apiKey)
            } catch (e: Exception) {
                Log.e(TAG, "⚠️  Initial heartbeat failed: ${e.message}")
            }
        }
    }

    private fun stopHeartbeat() {
        if (heartbeatJob != null) {
            Log.d(TAG, "🔴 Stopping heartbeat timer")
            heartbeatJob?.cancel()
            heartbeatJob = null
        }
    }

    private suspend fun sendHeartbeat(deviceId: String, apiKey: String) = withContext(Dispatchers.IO) {
        try {
            val url = URL("https://api.vulcainvpn.com/api/heartbeat/$deviceId")
            val connection = url.openConnection() as HttpURLConnection

            connection.apply {
                requestMethod = "POST"
                setRequestProperty("X-Api-Key", apiKey)
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = false
            }

            val responseCode = connection.responseCode

            if (responseCode == 200) {
                Log.d(TAG, "💓 Heartbeat sent successfully")
            } else {
                Log.w(TAG, "⚠️  Heartbeat failed: HTTP $responseCode")
            }

            connection.disconnect()

        } catch (e: Exception) {
            Log.e(TAG, "⚠️  Heartbeat error: ${e.message}")
            throw e
        }
    }

    // =============================
    // ⭐ STATE PERSISTENCE
    // =============================

    private fun setVpnState(running: Boolean) {
        prefs.edit().putBoolean(KEY_IS_RUNNING, running).apply()
        Log.d(TAG, "VPN state saved: $running")
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
