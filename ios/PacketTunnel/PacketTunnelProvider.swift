import NetworkExtension
import os.log

// TODO: import your sing-box iOS framework once Phase 1 (gomobile bind) is done, e.g.:
// import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("PacketTunnelProvider: startTunnel")

        // TODO:
        // 1. Read the sing-box JSON config written by the main app into the
        //    shared App Group container (see APP_GROUP constant), the same
        //    way vpn_config_service.dart builds it for other platforms.
        // 2. Boot sing-box against that config (mirror what libbox.aar does
        //    on Android — BoxService.start() equivalent on iOS is typically
        //    LibboxNewService(...) from the generated framework).
        // 3. Call setTunnelNetworkSettings(...) with the TUN interface
        //    settings sing-box expects, then call completionHandler(nil).

        completionHandler(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("PacketTunnelProvider: stopTunnel reason=%{public}@", String(describing: reason))
        // TODO: sing-box service.Close() equivalent
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Optional: two-way channel for the main app to query live stats
        // (bytes sent/received, current outbound) from the extension.
        completionHandler?(nil)
    }
}
