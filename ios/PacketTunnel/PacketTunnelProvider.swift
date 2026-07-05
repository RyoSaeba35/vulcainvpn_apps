import NetworkExtension
import Libbox
import os.log

/// PacketTunnelProvider — the iOS equivalent of Android's MyVpnService.kt.
///
/// Key differences from Android, confirmed from the actual generated
/// Libbox.objc.h header (not guessed):
///   - There's no LibboxNewService/BoxService on this build. Instead the API
///     is LibboxNewCommandServer(handler, platformInterface) -> CommandServer,
///     with .startOrReloadService(configContent, options, error) to start.
///   - openTun returns success via NSError, writing the fd into an out-param
///     (Obj-C calling convention for Go's (int, error) return).
///   - underNetworkExtension() must return true here (Android returns false).
///
/// The one non-obvious iOS-specific piece: NEPacketTunnelProvider's
/// `packetFlow` doesn't expose a raw file descriptor through any public
/// API, but sing-box's openTun needs one. The fix used here is the same
/// technique WireGuard's actual shipped iOS app uses: every packet tunnel
/// extension process has exactly one open socket with address family
/// AF_SYSTEM — found by scanning file descriptors with getpeername().
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private let appGroup = "group.com.vulcainvpn.app"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("PacketTunnelProvider: startTunnel")

        guard let config = readConfigFromAppGroup() else {
            os_log("PacketTunnelProvider: no config found in shared App Group container")
            completionHandler(NSError(domain: "VulcainVPN", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No VPN configuration found"]))
            return
        }

        // Apple requires network settings to be applied before the tunnel
        // is considered "up" — mirrors what Android's VpnService.Builder
        // does with addAddress/addRoute/addDnsServer, just via a different
        // Apple API shape.
        let settings = buildTunnelNetworkSettings()

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log("PacketTunnelProvider: setTunnelNetworkSettings failed: %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }

            do {
                try self.startLibbox(config: config)
                os_log("PacketTunnelProvider: libbox started successfully")
                completionHandler(nil)
            } catch {
                os_log("PacketTunnelProvider: libbox failed to start: %{public}@", error.localizedDescription)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("PacketTunnelProvider: stopTunnel reason=%{public}@", String(describing: reason))
        commandServer?.close()
        commandServer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Optional two-way channel for the main app to query live stats.
        // Not wired up yet — mirrors Android's statusSink, TODO for later.
        completionHandler?(nil)
    }

    // MARK: - Config loading

    /// Reads the sing-box JSON config from the shared App Group container.
    /// The main app (Flutter side, via vpn_service_ios.dart — not yet
    /// written) needs to write this file before starting the tunnel, the
    /// same JSON shape vpn_config_service.dart already builds for other
    /// platforms.
    private func readConfigFromAppGroup() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            os_log("PacketTunnelProvider: could not access App Group container")
            return nil
        }

        let configURL = containerURL.appendingPathComponent("vpn_config.json")
        return try? String(contentsOf: configURL, encoding: .utf8)
    }

    // MARK: - Network settings

    private func buildTunnelNetworkSettings() -> NEPacketTunnelNetworkSettings {
        // Placeholder addressing — matches the TUN address pattern used in
        // vpn_config_service.dart ("172.19.0.1/30" style). Adjust once the
        // real config parsing below extracts actual values instead of
        // hardcoding.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4Settings = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dnsSettings

        settings.mtu = 1420

        return settings
    }

    // MARK: - Libbox lifecycle

    private enum LibboxError: Error {
        case fdNotFound
        case serverCreationFailed
        case startFailed(String)
    }

    private func startLibbox(config: String) throws {
        LibboxSetMemoryLimit(true)

        let platformInterface = VulcainPlatformInterface(tunnelProvider: self)
        let handler = VulcainCommandServerHandler()

        var error: NSError?
        guard let server = LibboxNewCommandServer(handler, platformInterface, &error) else {
            throw LibboxError.serverCreationFailed
        }

        var startError: NSError?
        let started = server.startOrReloadService(config, options: nil, error: &startError)
        if !started {
            throw LibboxError.startFailed(startError?.localizedDescription ?? "unknown error")
        }

        commandServer = server
    }

    /// The WireGuard-proven technique for extracting a raw fd from
    /// NEPacketTunnelProvider's packetFlow, since no public API exposes it.
    /// Every packet tunnel extension process has exactly one open socket
    /// with address family AF_SYSTEM.
    fileprivate func extractTunnelFileDescriptor() -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
            var addr = sockaddr()
            if getpeername(fd, &addr, &addrLen) == 0 && addr.sa_family == AF_SYSTEM {
                return fd
            }
        }
        return nil
    }
}

/// Implements LibboxPlatformInterface — the iOS equivalent of Android's
/// MyVpnService implementing PlatformInterface. Method list confirmed
/// directly from the generated Libbox.objc.h header.
private class VulcainPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?, error: NSErrorPointer) -> Bool {
        guard let fd = tunnelProvider?.extractTunnelFileDescriptor() else {
            error?.pointee = NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find tunnel file descriptor"])
            return false
        }
        ret0_?.pointee = fd
        return true
    }

    func usePlatformAutoDetectInterfaceControl() -> Bool { true }

    func autoDetectInterfaceControl(_ fd: Int32, error: NSErrorPointer) -> Bool {
        // iOS sandboxes this differently than Android's protect(fd) — the
        // Network Extension entitlement + setTunnelNetworkSettings already
        // handles routing exclusion, so this is a no-op on iOS.
        return true
    }

    // Mirrors Android returning false here — iOS is the opposite, since
    // this literally IS a Network Extension.
    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }
    func useProcFS() -> Bool { false }

    func clearDNSCache() {}

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func sendNotification(_ notification: LibboxNotification?, error: NSErrorPointer) -> Bool {
        // TODO: bridge to UNUserNotificationCenter for user-visible alerts,
        // mirroring Android's NotificationService. Not critical for a
        // first working tunnel.
        return true
    }

    func getInterfaces(_ error: NSErrorPointer) -> (any LibboxNetworkInterfaceIteratorProtocol)? {
        // TODO: mirror Android's buildInterfaceCacheForNetwork. Returning
        // nil for now — sing-box falls back to its own interface detection.
        return nil
    }

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?, error: NSErrorPointer) -> Bool {
        return true
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?, error: NSErrorPointer) -> Bool {
        return true
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32, error: NSErrorPointer) -> LibboxConnectionOwner? {
        return nil
    }
}

/// Implements LibboxCommandServerHandler — mostly stubs for a first working
/// version. Real implementations would surface system-proxy status and
/// service reload/stop through this, but the core tunnel doesn't need it.
private class VulcainCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {

    func writeDebugMessage(_ message: String?) {
        os_log("libbox: %{public}@", message ?? "")
    }

    func getSystemProxyStatus(_ error: NSErrorPointer) -> LibboxSystemProxyStatus? {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool, error: NSErrorPointer) -> Bool { true }

    func serviceReload(_ error: NSErrorPointer) -> Bool { true }

    func serviceStop(_ error: NSErrorPointer) -> Bool { true }
}
