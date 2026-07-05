import NetworkExtension
import Libbox
import os.log

/// PacketTunnelProvider — the iOS equivalent of Android's MyVpnService.kt.
///
/// Swift bridging note: Objective-C methods ending in `error:(NSError**)`
/// get imported into Swift as `throws` functions — the BOOL/NSError**
/// mechanics are stripped from the Swift-visible signature, and any OTHER
/// genuine out-parameter (like openTun's fd) becomes the throwing
/// function's actual return value. This file was corrected after the
/// first build attempt wrote literal ObjC-style signatures instead.
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

        // LibboxNewCommandServer's trailing NSError** also bridges to throws.
        let server = try LibboxNewCommandServer(handler, platformInterface)
        guard let server = server else {
            throw NSError(domain: "VulcainVPN", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }

        // startOrReloadService's BOOL+error also bridges to a plain throws
        // call — the BOOL is dropped since throws already signals failure.
        try server.startOrReloadService(config, options: nil)

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

/// Implements LibboxPlatformInterfaceProtocol. Every method ending in
/// `error:` in the ObjC header below is written here as `throws` per
/// Swift's automatic NSError** bridging — this is why these signatures
/// look different from the raw Objective-C declarations.
private class VulcainPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
    }

    // ObjC: - (BOOL)openTun:options: ret0_:(int32_t*) error:(NSError**)
    // The ret0_ out-param becomes the throws function's return value.
    func openTun(_ options: LibboxTunOptionsProtocol?) throws -> Int32 {
        guard let fd = tunnelProvider?.extractTunnelFileDescriptor() else {
            throw NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find tunnel file descriptor"])
        }
        return fd
    }

    // Exact rename per Xcode's compiler diagnostic.
    func usePlatformAutoDetectControl() -> Bool { true }

    func autoDetectInterfaceControl(_ fd: Int32) throws {
        // No-op on iOS — setTunnelNetworkSettings + the NE entitlement
        // already handle routing exclusion, unlike Android's protect(fd).
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func useProcFS() -> Bool { false }
    func clearDNSCache() {}

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

    func sendNotification(_ notification: LibboxNotification?) throws {
        // TODO: bridge to UNUserNotificationCenter, mirroring Android's
        // NotificationService. Not critical for a first working tunnel.
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol? {
        // TODO: mirror Android's buildInterfaceCacheForNetwork.
        return nil
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner? {
        return nil
    }
}

/// Implements LibboxCommandServerHandlerProtocol — mostly stubs for a
/// first working version. Same throws-bridging convention applies.
private class VulcainCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {

    func writeDebugMessage(_ message: String?) {
        os_log("libbox: %{public}@", message ?? "")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus? {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {}
    func serviceReload() throws {}
    func serviceStop() throws {}
}
