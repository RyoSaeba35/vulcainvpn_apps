import NetworkExtension
import os.log

// STUB — this is intentionally minimal. The real implementation should
// port the proven logic from ios/PacketTunnel/PacketTunnelProvider.swift:
//   - CommandServer/Libbox setup (LibboxSetup, pointed at the App Group
//     container, same as iOS)
//   - getInterfaces() returning CIDR-format addresses (NOT bare IPs —
//     this was the exact cause of a sing-box panic on iOS, see commit
//     "Fix the actual crash: getInterfaces() must return CIDR addresses")
//   - autoDetectControl / IP_BOUND_IF binding logic
//   - stderr redirection for Go panic capture (VulcainLogger pattern)
//   - packetFlow.readPackets() liveness loop
// NetworkExtension APIs are shared between iOS and macOS, so most of that
// Swift code should port with minimal changes — the macOS-specific delta
// is mainly around how the extension gets activated (OSSystemExtensionRequest
// from the main app) rather than the tunnel logic itself.
class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("PacketTunnelMac: startTunnel called (stub)")
        completionHandler(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("PacketTunnelMac: stopTunnel called (stub)")
        completionHandler()
    }
}
