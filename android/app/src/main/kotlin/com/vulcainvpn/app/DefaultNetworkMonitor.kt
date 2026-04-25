package com.vulcainvpn.app

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.InterfaceUpdateListener
import kotlinx.coroutines.*  // 🔧 FIX #3: For proper coroutine usage

object DefaultNetworkMonitor {

    private const val TAG = "DefaultNetworkMonitor"

    var defaultNetwork: Network? = null
    private var listener: InterfaceUpdateListener? = null
    private var connectivityManager: ConnectivityManager? = null

    // Callback to pre-cache interfaces before updating sing-box
    var onInterfaceCacheRequest: ((Network?) -> Unit)? = null

    // 🔧 FIX #3: Use supervised scope instead of GlobalScope
    private var monitorScope: CoroutineScope? = null

    suspend fun start(cm: ConnectivityManager) {
        Log.d(TAG, "🔍 Starting DefaultNetworkMonitor")
        connectivityManager = cm

        // 🔧 FIX #3: Create supervised scope for network monitoring
        monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

        // Set CM for DefaultNetworkListener
        DefaultNetworkListener.setConnectivityManager(cm)

        // Register with the actor - it will handle all network changes
        DefaultNetworkListener.start(this) { network ->
            defaultNetwork = network
            checkDefaultInterfaceUpdate(network)
        }

        // Get initial network
        defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            cm.activeNetwork
        } else {
            DefaultNetworkListener.get()
        }

        Log.d(TAG, "✅ Initial network: $defaultNetwork")
    }

    suspend fun stop() {
        Log.d(TAG, "🔍 Stopping DefaultNetworkMonitor")

        // 🔧 FIX #3: Cancel scope before stopping listener
        try {
            monitorScope?.cancel()
            monitorScope = null
        } catch (e: Exception) {
            Log.e(TAG, "Error cancelling monitor scope: ${e.message}")
        }

        DefaultNetworkListener.stop(this)
        connectivityManager = null
        listener = null
        defaultNetwork = null
        onInterfaceCacheRequest = null
    }

    fun setListener(newListener: InterfaceUpdateListener?) {
        Log.d(TAG, "🔍 setListener called: ${newListener != null}")
        listener = newListener

        // Trigger initial update
        if (newListener != null) {
            checkDefaultInterfaceUpdate(defaultNetwork)
        }
    }

    private fun checkDefaultInterfaceUpdate(newNetwork: Network?) {
        val listener = listener ?: return
        val cm = connectivityManager ?: return

        if (newNetwork != null) {
            val linkProperties = cm.getLinkProperties(newNetwork)
            val interfaceName = linkProperties?.interfaceName

            if (interfaceName == null) {
                Log.w(TAG, "⚠️ No interface name for network")
                return
            }

            // CRITICAL: Skip VPN interfaces - don't send any updates
            if (interfaceName.startsWith("tun") || interfaceName.startsWith("ppp")) {
                Log.d(TAG, "⏭️ Skipping VPN interface: $interfaceName")
                return
            }

            // Try to get interface index with retries
            var interfaceIndex = -1
            for (attempt in 0 until 10) {
                try {
                    interfaceIndex = java.net.NetworkInterface.getByName(interfaceName)?.index ?: -1
                    if (interfaceIndex != -1) break
                } catch (e: Exception) {
                    if (attempt < 9) {
                        Thread.sleep(100)
                    }
                }
            }

            val networkCapabilities = cm.getNetworkCapabilities(newNetwork)
            val isExpensive = networkCapabilities?.let {
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            } ?: false

            val isConstrained = networkCapabilities?.let {
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            } ?: false

            Log.d(TAG, "✅ Preparing to update interface: name=$interfaceName, index=$interfaceIndex")

            // 🔧 FIX #3: Use monitor scope instead of GlobalScope
            // This ensures cleanup when monitor is stopped
            val scope = monitorScope ?: run {
                Log.w(TAG, "⚠️ Monitor scope is null, cannot update interface")
                return
            }

            scope.launch(Dispatchers.IO) {
                try {
                    // Step 1: Request the service to build and cache interfaces
                    Log.d(TAG, "📦 Requesting interface cache build...")
                    onInterfaceCacheRequest?.invoke(newNetwork)

                    // Step 2: Small delay to ensure cache is built
                    delay(100)

                    // Step 3: Now safely notify sing-box
                    Log.d(TAG, "📡 Notifying sing-box: $interfaceName (index=$interfaceIndex)")
                    listener.updateDefaultInterface(interfaceName, interfaceIndex, isExpensive, isConstrained)
                    Log.d(TAG, "✅ Interface update completed")
                } catch (e: CancellationException) {
                    // 🔧 FIX #3: Handle cancellation gracefully
                    Log.d(TAG, "Interface update cancelled (normal shutdown)")
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Failed to update interface", e)
                }
            }
        } else {
            Log.d(TAG, "⚠️ No default network")
        }
    }
}
