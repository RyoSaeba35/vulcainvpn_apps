import NetworkExtension
import Network
import Libbox

/// PacketTunnelProvider — macOS port of ios/PacketTunnel/PacketTunnelProvider.swift.
///
/// PORT NOTES (macOS vs iOS):
/// - App Group changed to "group.com.vulcainvpn.app.macos" (macOS uses a
///   separate App Group from iOS — see scaffold_macos_extension.rb).
/// - Everything else here is expected to behave identically to iOS, since
///   NEPacketTunnelProvider, NWPathMonitor, getifaddrs()/POSIX socket APIs,
///   and IP_BOUND_IF/IPV6_BOUND_IF are all shared Darwin/Apple-platform
///   APIs, not iOS-specific ones.
/// - UNVERIFIED: the exact Swift method names Libbox.xcframework exposes
///   for macOS (autoDetectControl, usePlatformAutoDetectControl, send,
///   etc.) were only confirmed for iOS via real compiler errors against a
///   real-built framework — see the extensive comment history in the iOS
///   version of this file. The macOS-target gomobile build SHOULD produce
///   the same bindings (same Go source), but this needs to be confirmed
///   against an actual Codemagic build log, not assumed. If the compiler
///   rejects any of the method names/signatures below, that's expected —
///   fix forward the same way the iOS version was debugged.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private let appGroup = "group.com.vulcainvpn.app.macos"
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
        redirectGoStderr()
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

    private func redirectGoStderr() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            VulcainLogger.error("Extension", "could not access App Group container for stderr redirect")
            return
        }

        let stderrPath = containerURL.appendingPathComponent("libbox_stderr.log").path
        var redirectError: NSError?
        LibboxRedirectStderr(stderrPath, &redirectError)
        if let redirectError = redirectError {
            VulcainLogger.error("Extension", "LibboxRedirectStderr failed: \(redirectError.localizedDescription)")
        } else {
            VulcainLogger.log("Extension", "Go stderr redirected to \(stderrPath)")
        }
    }

    // MARK: - Heartbeat (diagnostic only)

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
    // Carried over from iOS as a precaution, NOT a confirmed macOS
    // requirement. The original hypothesis was that iOS's extension
    // liveness tracking needs to see Swift-side packetFlow activity to
    // avoid treating the extension as idle. System Extensions on macOS may
    // have different lifecycle management than iOS app extensions — this
    // may turn out to be unnecessary here. Left in because it's harmless
    // either way; remove later if confirmed unneeded.
    private func startPacketFlowLoop() {
        packetFlowLoopActive = true
        VulcainLogger.log("Extension", "starting packetFlow.readPackets() liveness loop")
        pumpPacketFlow()
    }

    private func pumpPacketFlow() {
        guard packetFlowLoopActive else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.packetFlowLoopActive else { return }
            self.pumpPacketFlow()
        }
    }
}

// MARK: - Simple iterator helpers (Swift → Libbox direction)

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
        let fd = LibboxGetTunnelFileDescriptor()
        VulcainLogger.log("Extension", "LibboxGetTunnelFileDescriptor() returned fd: \(fd)")
        guard fd >= 0 else {
            throw NSError(domain: "VulcainVPN", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "LibboxGetTunnelFileDescriptor returned invalid fd"])
        }
        ret0_?.pointee = fd
    }

    func usePlatformAutoDetectControl() -> Bool { true }

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

    func send(_ notification: LibboxNotification?) throws {
        // TODO: bridge to UNUserNotificationCenter, mirroring
        // macos_notification_service.dart. Not critical for a working tunnel.
    }

    /// Same getifaddrs()-based implementation as iOS. Interface-type
    /// classification (en0=WiFi, pdp_ip*=Cellular) is iOS-specific and
    /// mostly meaningless on a Mac (en0 could be Wi-Fi OR Ethernet
    /// depending on the machine) — classified as WIFI or Other only,
    /// since there's no cellular case on macOS and sing-box mostly just
    /// needs SOME valid interface list, not perfect type accuracy.
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        var interfaces: [LibboxNetworkInterface] = []

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            VulcainLogger.error("Extension", "getifaddrs() failed")
            throw NSError(domain: "VulcainVPN", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "getifaddrs failed"])
        }
        defer { freeifaddrs(ifaddrPtr) }

        var addressesByName: [String: [String]] = [:]
        var indexByName: [String: Int32] = [:]
        var flagsByName: [String: Int32] = [:]

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)

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
                    var address = String(cString: hostBuffer)

                    if address.hasPrefix("fe80:") || address.hasPrefix("169.254.") {
                        continue
                    }

                    if let percentIndex = address.firstIndex(of: "%") {
                        address = String(address[address.startIndex..<percentIndex])
                    }

                    // Same CIDR-format fix as iOS — sing-box's
                    // NetworkInterfaces() calls netip.ParsePrefix on each
                    // address and panics fatally without a "/prefixlen".
                    let prefixLength = family == UInt8(AF_INET) ? "32" : "128"
                    let addressWithPrefix = "\(address)/\(prefixLength)"

                    addressesByName[name, default: []].append(addressWithPrefix)
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
            iface.type = name.hasPrefix("en") ? LibboxInterfaceTypeWIFI : LibboxInterfaceTypeOther
            interfaces.append(iface)
        }

        VulcainLogger.log("Extension", "getInterfaces() found \(interfaces.count) interfaces: \(interfaces.map { $0.name })")
        return VulcainNetworkInterfaceIterator(interfaces)
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
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

    /// On a Mac, prefer en0/en1 (Wi-Fi or Ethernet) over utun/ipsec/etc.
    /// No pdp_ip* cellular case on macOS.
    private func firstUsableInterfaceName() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [String] = []
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            if name.hasPrefix("en") {
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
