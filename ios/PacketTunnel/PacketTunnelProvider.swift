import NetworkExtension
import Network
import Libbox

/// PacketTunnelProvider — the iOS equivalent of Android's MyVpnService.kt.
///
/// IMPORTANT LEARNING: gomobile/gobind attaches hidden Swift-name-rename
/// annotations to some ObjC methods that do NOT show up in the plain
/// Libbox.objc.h header text. The header shows e.g.
/// "autoDetectInterfaceControl:error:", but Swift actually requires
/// "autoDetectControl(_:)" — confirmed via compiler diagnostics like
/// "'autoDetectInterfaceControl' has been renamed to 'autoDetectControl(_:)'".
/// So for THESE THREE methods specifically, the correct Swift names are
/// shorter than what the raw header suggests: autoDetectControl (not
/// autoDetectInterfaceControl), usePlatformAutoDetectControl (not
/// usePlatformAutoDetectInterfaceControl), send (not sendNotification).
/// LibboxSetup, by contrast, is a free/global function and does NOT bridge
/// to throws at all (needs the explicit NSError** form) — free functions
/// don't get the throws-bridging treatment regardless of BOOL vs nullable-
/// object return shape, only protocol/class methods do.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private let appGroup = "group.com.vulcainvpn.app"
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatCount = 0
    private var packetFlowLoopActive = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        VulcainLogger.log("Extension", "startTunnel called")

        guard let config = readConfigFromAppGroup() else {
            VulcainLogger.error("Extension", "no config found in shared App Group container")
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
                self.startHeartbeat()
                self.startPacketFlowLoop()
                completionHandler(nil)
            } catch {
                VulcainLogger.error("Extension", "libbox failed to start: \(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        VulcainLogger.log("Extension", "stopTunnel reason=\(String(describing: reason))")
        stopHeartbeat()
        packetFlowLoopActive = false

        let serverToClose = commandServer
        commandServer = nil
        completionHandler()

        DispatchQueue.global(qos: .utility).async {
            serverToClose?.close()
            VulcainLogger.log("Extension", "commandServer.close() finished (async)")
        }
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

    /// LibboxSetup is BOOL+error like startOrReloadService (which we've
    /// confirmed bridges to throws), so this should too — not the explicit
    /// error-pointer form used in the previous version of this file.
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

    // MARK: - Heartbeat (diagnostic only — measures exact survival time)

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.heartbeatCount += 1
            VulcainLogger.log("Extension", "heartbeat #\(self.heartbeatCount) — still alive")
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Packet flow liveness loop
    //
    // libbox reads/writes the tunnel's raw fd directly via POSIX calls
    // (that's what LibboxGetTunnelFileDescriptor() + openTun hands it) —
    // so this loop does NOT process any actual packet data. Its only job
    // is calling packetFlow.readPackets() so iOS's own liveness/activity
    // tracking for the extension sees Swift-side engagement with the
    // NEPacketTunnelFlow API. Hypothesis: without this, iOS may treat the
    // extension as idle and terminate it after a few seconds — which
    // matches the observed ~5s survival time with zero heartbeats firing.
    private func startPacketFlowLoop() {
        packetFlowLoopActive = true
        VulcainLogger.log("Extension", "starting packetFlow.readPackets() liveness loop")
        pumpPacketFlow()
    }

    private func pumpPacketFlow() {
        guard packetFlowLoopActive else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.packetFlowLoopActive else { return }
            // Not forwarding these anywhere — libbox already has the raw
            // fd and handles the actual data path itself. This call's
            // purpose is purely to keep iOS's liveness tracking satisfied.
            self.pumpPacketFlow()
        }
    }
}

// MARK: - Simple iterator helpers (Swift → Libbox direction)

/// Plain Swift-backed implementation of LibboxStringIteratorProtocol, for
/// cases where WE need to hand libbox a list of strings (e.g. an
/// interface's addresses), as opposed to receiving one FROM libbox (which
/// uses the Go-backed LibboxStringIterator concrete class instead).
private class VulcainStringIterator: NSObject, LibboxStringIteratorProtocol {
    private var items: [String]
    private var index = 0

    init(_ items: [String]) {
        self.items = items
    }

    func hasNext() -> Bool { index < items.count }
    func len() -> Int32 { Int32(items.count) }
    func next() -> String {
        guard index < items.count else { return "" }
        let value = items[index]
        index += 1
        return value
    }
}

private class VulcainNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var items: [LibboxNetworkInterface]
    private var index = 0

    init(_ items: [LibboxNetworkInterface]) {
        self.items = items
    }

    func hasNext() -> Bool { index < items.count }
    func next() -> LibboxNetworkInterface? {
        guard index < items.count else { return nil }
        let value = items[index]
        index += 1
        return value
    }
}

/// Implements LibboxPlatformInterfaceProtocol.
private class VulcainPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var tunnelProvider: PacketTunnelProvider?
    private var pathMonitor: NWPathMonitor?
    private var currentInterfaceIndex: Int32 = 0

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
        super.init()
        if let initialInterface = firstUsableInterfaceName() {
            currentInterfaceIndex = Int32(if_nametoindex(initialInterface))
            VulcainLogger.log("Extension", "initial default interface (at init): \(initialInterface) (index \(currentInterfaceIndex))")
        }
    }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        // Official API — replaces the previous getpeername/AF_SYSTEM
        // fd-scanning hack, which was a WireGuard-specific technique that
        // may not have been reliable for sing-box's own tun handling.
        let fd = LibboxGetTunnelFileDescriptor()
        VulcainLogger.log("Extension", "LibboxGetTunnelFileDescriptor() returned fd: \(fd)")
        guard fd >= 0 else {
            throw NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "LibboxGetTunnelFileDescriptor returned invalid fd"])
        }
        ret0_?.pointee = fd
    }

    // gomobile adds hidden swift_name annotations that don't appear in the
    // plain ObjC header text — the real Swift-facing name is
    // usePlatformAutoDetectControl, confirmed by compiler diagnostic
    // ("has been renamed to usePlatformAutoDetectControl()").
    func usePlatformAutoDetectControl() -> Bool { true }

    // Real Swift-facing name is autoDetectControl, not
    // autoDetectInterfaceControl (same swift_name situation as above).
    //
    // This is likely the actual root cause of "tunnel connects but no
    // traffic flows": sing-box calls this for its OWN outbound connections
    // (to the real WireGuard/Hysteria2/Shadowsocks server), expecting the
    // platform to bind that socket to the physical interface, bypassing
    // our own 0.0.0.0/0 tunnel route. Without this, those outbound sockets
    // get captured by our own tunnel — a routing loop that means sing-box
    // can never actually reach the real remote server, so no traffic ever
    // flows, and iOS's reachability watchdog kills the extension after
    // ~5s of apparent inactivity (matches the exact timing observed).
    func autoDetectControl(_ fd: Int32) throws {
        guard currentInterfaceIndex > 0 else {
            VulcainLogger.error("Extension", "autoDetectControl called but no default interface index known yet")
            return
        }

        var index = currentInterfaceIndex
        let ipv4Result = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<Int32>.size))
        var index6 = currentInterfaceIndex
        let ipv6Result = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index6, socklen_t(MemoryLayout<Int32>.size))

        if ipv4Result != 0 && ipv6Result != 0 {
            VulcainLogger.error("Extension", "autoDetectControl: setsockopt failed for fd \(fd), interface index \(currentInterfaceIndex) (errno \(errno))")
        } else {
            VulcainLogger.log("Extension", "autoDetectControl: bound fd \(fd) to interface index \(currentInterfaceIndex)")
        }
    }

    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func useProcFS() -> Bool { false }
    func clearDNSCache() {}

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

    // Real Swift-facing name is send, not sendNotification (same
    // swift_name situation — confirmed by compiler diagnostic).
    func send(_ notification: LibboxNotification?) throws {
        // TODO: bridge to UNUserNotificationCenter, mirroring Android's
        // NotificationService. Not critical for a working tunnel.
    }

    /// Real implementation using getifaddrs() — previously a stub that
    /// threw "not implemented". Likely root cause of "tunnel connects but
    /// no internet": the config has auto_detect_interface:true, which
    /// depends on this to know which physical interface (Wi-Fi/cellular)
    /// sing-box should bind its own outbound connections to.
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        var interfaces: [LibboxNetworkInterface] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            VulcainLogger.error("Extension", "getifaddrs() failed")
            throw NSError(domain: "VulcainVPN", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "getifaddrs failed"])
        }
        defer { freeifaddrs(ifaddrPtr) }

        // Group addresses by interface name first, since getifaddrs gives
        // one entry per address (an interface with both IPv4 and IPv6 shows
        // up twice), but Libbox wants one LibboxNetworkInterface per
        // physical interface with an addresses list.
        var addressesByName: [String: [String]] = [:]
        var indexByName: [String: Int32] = [:]
        var flagsByName: [String: Int32] = [:]

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)

            // Skip loopback and non-running interfaces — libbox doesn't
            // need those, and including them just adds noise/risk.
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            indexByName[name] = Int32(if_nametoindex(name))
            flagsByName[name] = flags

            guard let addr = interface.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostBuffer, socklen_t(hostBuffer.count),
                    nil, 0, NI_NUMERICHOST
                )
                if result == 0 {
                    let address = String(cString: hostBuffer)
                    addressesByName[name, default: []].append(address)
                }
            }
        }

        for (name, addresses) in addressesByName {
            let iface = LibboxNetworkInterface()
            iface.name = name
            iface.index = indexByName[name] ?? 0
            iface.mtu = 1500
            iface.addresses = VulcainStringIterator(addresses)
            iface.flags = flagsByName[name] ?? 0
            iface.metered = false
            // en0 is Wi-Fi, pdp_ip* are cellular on iOS — best-effort type
            // classification since sing-box mostly just needs SOME valid
            // interface list, not perfect type accuracy.
            if name.hasPrefix("en") {
                iface.type = LibboxInterfaceTypeWIFI
            } else if name.hasPrefix("pdp_ip") {
                iface.type = LibboxInterfaceTypeCellular
            } else {
                iface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(iface)
        }

        VulcainLogger.log("Extension", "getInterfaces() found \(interfaces.count) interfaces: \(interfaces.map { $0.name })")
        return VulcainNetworkInterfaceIterator(interfaces)
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        // Initial synchronous best-effort lookup so currentInterfaceIndex
        // isn't 0 if autoDetectControl gets called before NWPathMonitor's
        // first async callback fires.
        if let initialInterface = firstUsableInterfaceName() {
            currentInterfaceIndex = Int32(if_nametoindex(initialInterface))
            VulcainLogger.log("Extension", "initial default interface: \(initialInterface) (index \(currentInterfaceIndex))")
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            let interfaceName = path.availableInterfaces.first?.name ?? ""
            let interfaceIndex = Int32(if_nametoindex(interfaceName))
            self?.currentInterfaceIndex = interfaceIndex
            listener?.updateDefaultInterface(
                interfaceName,
                interfaceIndex: interfaceIndex,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            VulcainLogger.log("Extension", "default interface updated: \(interfaceName) (index \(interfaceIndex))")
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    /// Best-effort synchronous interface pick for the initial value —
    /// prefers en0 (Wi-Fi) or pdp_ip* (cellular) over utun/ipsec/etc.
    private func firstUsableInterfaceName() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [String] = []
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                candidates.append(name)
            }
        }
        return candidates.first
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

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
