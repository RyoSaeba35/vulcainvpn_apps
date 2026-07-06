import NetworkExtension
import Libbox

/// PacketTunnelProvider — the iOS equivalent of Android's MyVpnService.kt.
///
/// NOTE: if your current project already has a more complete/updated
/// version of this file (matching a newer VpnManager.swift), merge these
/// VulcainLogger.log(...) calls into YOUR current version rather than
/// overwriting it wholesale — the logging additions are what matters here,
/// not this specific structure.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private let appGroup = "group.com.vulcainvpn.app"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        VulcainLogger.log("Extension", "startTunnel called")

        guard let config = readConfigFromAppGroup() else {
            VulcainLogger.error("Extension", "no config found in shared App Group container — check App Group entitlement on BOTH targets, and that VpnManager wrote vpn_config.json before calling startVPNTunnel()")
            completionHandler(NSError(domain: "VulcainVPN", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No VPN configuration found"]))
            return
        }
        VulcainLogger.log("Extension", "config read successfully (\(config.count) chars)")

        let settings = buildTunnelNetworkSettings()

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                VulcainLogger.error("Extension", "setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            VulcainLogger.log("Extension", "setTunnelNetworkSettings succeeded")

            do {
                try self.startLibbox(config: config)
                VulcainLogger.log("Extension", "libbox started successfully — tunnel should be up")
                completionHandler(nil)
            } catch {
                VulcainLogger.error("Extension", "libbox failed to start: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        VulcainLogger.log("Extension", "stopTunnel reason=\(String(describing: reason))")
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
            VulcainLogger.error("Extension", "could not access App Group container \(appGroup)")
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
        try setupLibboxPaths()
        LibboxSetMemoryLimit(true)

        let platformInterface = VulcainPlatformInterface(tunnelProvider: self)
        let handler = VulcainCommandServerHandler()

        var createError: NSError?
        guard let server = LibboxNewCommandServer(handler, platformInterface, &createError) else {
            VulcainLogger.error("Extension", "LibboxNewCommandServer returned nil: \(createError?.localizedDescription ?? "no error detail")")
            throw createError ?? NSError(domain: "VulcainVPN", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }
        VulcainLogger.log("Extension", "LibboxNewCommandServer created")

        let overrideOptions = LibboxOverrideOptions()
        try server.startOrReloadService(config, options: overrideOptions)
        VulcainLogger.log("Extension", "startOrReloadService succeeded")

        commandServer = server
    }

    /// sing-box tries to write a cache database (cache.db) and other state
    /// to its default working directory, but that default location isn't
    /// writable from inside the Network Extension sandbox ("operation not
    /// permitted"). LibboxSetup tells it to use the shared App Group
    /// container instead, which we DO have write access to.
    ///
    /// NOTE: exact parameter names/bridging are a best-effort guess based
    /// on the standard sing-box mobile setup pattern (matches the official
    /// sing-box-for-apple client) — if this doesn't compile, the compiler
    /// error will show the real signature, same as it did for openTun
    /// earlier in this file.
    private func setupLibboxPaths() throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw NSError(domain: "VulcainVPN", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Could not access App Group container for Libbox setup"])
        }

        let basePath = containerURL.appendingPathComponent("sing-box").path
        let workingPath = containerURL.appendingPathComponent("sing-box/working").path
        let tempPath = containerURL.appendingPathComponent("sing-box/temp").path

        for path in [basePath, workingPath, tempPath] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingPath
        options.tempPath = tempPath

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError = setupError {
            VulcainLogger.error("Extension", "LibboxSetup failed: \(setupError.localizedDescription)")
            throw setupError
        }
        VulcainLogger.log("Extension", "LibboxSetup succeeded, basePath=\(basePath)")
    }

    /// WireGuard's proven technique for extracting a raw fd from
    /// NEPacketTunnelProvider's packetFlow. Logged explicitly since this is
    /// the single most likely point of silent failure — if this returns
    /// nil, sing-box never gets a real interface to read/write packets.
    fileprivate func extractTunnelFileDescriptor() -> Int32? {
        for fd: Int32 in 0...1024 {
            var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
            var addr = sockaddr()
            if getpeername(fd, &addr, &addrLen) == 0 && addr.sa_family == AF_SYSTEM {
                VulcainLogger.log("Extension", "found tunnel fd: \(fd)")
                return fd
            }
        }
        VulcainLogger.error("Extension", "extractTunnelFileDescriptor found NO matching fd in range 0...1024 — this is likely why the tunnel fails")
        return nil
    }
}

/// Implements LibboxPlatformInterfaceProtocol.
private class VulcainPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        VulcainLogger.log("Extension", "libbox called openTun")
        guard let fd = tunnelProvider?.extractTunnelFileDescriptor() else {
            throw NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not find tunnel file descriptor"])
        }
        ret0_?.pointee = fd
    }

    func usePlatformAutoDetectControl() -> Bool { true }

    func autoDetectControl(_ fd: Int32) throws {
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

    func send(_ notification: LibboxNotification?) throws {
        // TODO: bridge to UNUserNotificationCenter, mirroring Android's
        // NotificationService. Not critical for a first working tunnel.
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
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
        VulcainLogger.log("libbox", message ?? "")
    }

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
