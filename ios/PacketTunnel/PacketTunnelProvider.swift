import NetworkExtension
import Libbox
import os.log

/// PacketTunnelProvider — the iOS equivalent of Android's MyVpnService.kt.
///
/// Swift/ObjC bridging rule that matters here (confirmed via three rounds
/// of real compiler errors — this genuinely can't be known in advance
/// without seeing gomobile's specific output compile):
///   - Methods whose ObjC return is BOOL with NSError** (void-like, no
///     other meaningful return) bridge to Swift `throws` (Void return).
///   - Methods whose ObjC return is a NULLABLE OBJECT with NSError**
///     bridge to `throws -> T` where T is NON-optional — the nullability
///     is fully absorbed into the throws mechanism, not kept as Optional.
///     (Writing `throws -> T?` or plain non-throwing `-> T?` both fail —
///     it must be exactly `throws -> T`.)
///   - Free C functions (FOUNDATION_EXPORT) with NSError** do NOT get
///     auto-bridged to throws at all — the NSErrorPointer stays a real,
///     literal parameter you must pass explicitly.
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
        completionHandler?(nil)
    }

    // MARK: - Config loading

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

    private func startLibbox(config: String) throws {
        LibboxSetMemoryLimit(true)

        let platformInterface = VulcainPlatformInterface(tunnelProvider: self)
        let handler = VulcainCommandServerHandler()

        // Free C function returning a nullable object + NSError** does NOT
        // bridge to throws — the error param stays literal.
        var createError: NSError?
        guard let server = LibboxNewCommandServer(handler, platformInterface, &createError) else {
            throw createError ?? NSError(domain: "VulcainVPN", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }

        // startOrReloadService returns BOOL (void-like) — this one does
        // bridge to throws. Passing an explicit LibboxOverrideOptions
        // instead of nil avoids Swift overload-resolution ambiguity.
        let overrideOptions = LibboxOverrideOptions()
        try server.startOrReloadService(config, options: overrideOptions)

        commandServer = server
    }

    /// WireGuard's proven technique for extracting a raw fd from
    /// NEPacketTunnelProvider's packetFlow — no public API exposes it, but
    /// every packet tunnel extension process has exactly one open socket
    /// with address family AF_SYSTEM.
    fileprivate func extractTunnelFileDescriptor() -> Int32? {
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

/// Implements LibboxPlatformInterfaceProtocol.
private class VulcainPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
    }

    // BOOL + separate real out-param (ret0_) -> bridges to throws -> Int32.
    func openTun(_ options: any LibboxTunOptionsProtocol) throws -> Int32 {
        guard let fd = tunnelProvider?.extractTunnelFileDescriptor() else {
            throw NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find tunnel file descriptor"])
        }
        return fd
    }

    func usePlatformAutoDetectControl() -> Bool { true }

    // Renamed per second round of compiler diagnostics.
    // BOOL, void-like -> still bridges to throws.
    func autoDetectControl(_ fd: Int32) throws {
        // No-op on iOS — setTunnelNetworkSettings + the NE entitlement
        // already handle routing exclusion, unlike Android's protect(fd).
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func useProcFS() -> Bool { false }
    func clearDNSCache() {}

    // No error param in the ObjC header at all for these two — plain optional.
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

    // Renamed to send(_:) — BOOL, void-like -> still bridges to throws.
    func send(_ notification: LibboxNotification?) throws {
        // TODO: bridge to UNUserNotificationCenter, mirroring Android's
        // NotificationService. Not critical for a first working tunnel.
    }

    // Nullable-object return + error bridges to throws -> NON-optional T
    // (the nullability is absorbed into the throws mechanism itself).
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        // TODO: mirror Android's buildInterfaceCacheForNetwork.
        throw NSError(domain: "VulcainVPN", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "getInterfaces not implemented"])
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "VulcainVPN", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner not implemented"])
    }
}

/// Implements LibboxCommandServerHandlerProtocol.
private class VulcainCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {

    func writeDebugMessage(_ message: String?) {
        os_log("libbox: %{public}@", message ?? "")
    }

    // Same rule: nullable-object return + error -> throws with non-optional T.
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {}
    func serviceReload() throws {}
    func serviceStop() throws {}
}
