import Foundation
import NetworkExtension
import Flutter

// Runs in the MAIN APP process (not the PacketTunnel extension).
// This is the iOS equivalent of your Android MethodChannel handler —
// but instead of driving libbox directly, it asks iOS to manage the
// PacketTunnel extension's lifecycle via NETunnelProviderManager.
//
// IMPORTANT: PacketTunnelProvider.readConfigFromAppGroup() reads the
// config from a FILE in the shared App Group container
// (vpn_config.json), NOT from providerConfiguration. So the real
// hand-off happens via writeConfigToAppGroup below — providerConfiguration
// is only used here for metadata NETunnelProviderProtocol requires.

class VpnManager: NSObject {
    static let shared = VpnManager()

    private var eventSink: FlutterEventSink?
    private var statusObserver: NSObjectProtocol?

    // Must match codemagic.yaml's EXT_BUNDLE_ID.
    private let providerBundleIdentifier = "com.vulcainvpn.app.PacketTunnel"

    // Must match the App Group registered in both targets' entitlements
    // AND PacketTunnelProvider's `appGroup` constant.
    private let appGroup = "group.com.vulcainvpn.app"

    // MARK: - Public entry points, called from AppDelegate's channel setup

    func setup(methodChannel: FlutterMethodChannel, eventChannel: FlutterEventChannel) {
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        eventChannel.setStreamHandler(self)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startVpn":
            guard let args = call.arguments as? [String: Any],
                  let config = args["config"] as? String,
                  let accessToken = args["access_token"] as? String,
                  let serverAddress = args["server_address"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "Missing config/access_token/server_address", details: nil))
                return
            }
            startVpn(config: config, accessToken: accessToken, serverAddress: serverAddress, result: result)

        case "stopVpn":
            stopVpn(result: result)

        case "checkNotificationPermission":
            // iOS notification permission is handled separately via
            // UNUserNotificationCenter if/when you wire that up. Returning
            // true here so it doesn't block VPN flow — revisit if you add
            // push notifications on iOS.
            result(true)

        case "checkForDeathEvents":
            // No persisted death-event store on iOS yet (Android uses
            // SharedPreferences for this). NEVPNStatus changes are pushed
            // live via the event channel instead — see emitStatus.
            result(nil)

        case "getLogSizeKB":
            result(VulcainLogger.sizeKB())

        case "getLogs":
            result(VulcainLogger.readAll() ?? "")

        case "clearLogs":
            VulcainLogger.clear()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Config hand-off (App Group shared file)

    /// Writes vpn_config.json into the shared App Group container.
    /// This is the ONLY thing PacketTunnelProvider actually reads —
    /// providerConfiguration is not consulted by the extension at all
    /// right now, so this write MUST happen before startVPNTunnel().
    private func writeConfigToAppGroup(config: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw NSError(domain: "VulcainVPN", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Could not access App Group container \(appGroup) — check entitlements on BOTH targets"])
        }

        let configURL = containerURL.appendingPathComponent("vpn_config.json")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Start

    private func startVpn(config: String, accessToken: String, serverAddress: String, result: @escaping FlutterResult) {
        VulcainLogger.log("MainApp", "startVpn called, config \(config.count) chars")
        do {
            try writeConfigToAppGroup(config: config)
            VulcainLogger.log("MainApp", "config written to App Group container")
        } catch {
            VulcainLogger.error("MainApp", "writeConfigToAppGroup failed: \(error.localizedDescription)")
            result(FlutterError(code: "CONFIG_WRITE_FAILED", message: error.localizedDescription, details: nil))
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }

            if let error = error {
                result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
                return
            }

            let manager = managers?.first ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleIdentifier
            proto.serverAddress = serverAddress
            // Not read by the extension today (it reads the App Group file
            // instead), but harmless to keep here — NETunnelProviderProtocol
            // requires providerConfiguration to be non-nil for some iOS
            // versions' validation, and access_token may be useful here
            // later if the extension needs to call your API directly
            // (e.g. for a heartbeat), mirroring Android's pattern.
            proto.providerConfiguration = ["access_token": accessToken]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "VulcainVPN"
            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error = error {
                    result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil))
                    return
                }

                // Reload after save — Apple's API requires this dance,
                // saving can invalidate the in-memory manager reference.
                manager.loadFromPreferences { error in
                    if let error = error {
                        result(FlutterError(code: "RELOAD_FAILED", message: error.localizedDescription, details: nil))
                        return
                    }

                    self.observeStatus(manager: manager)

                    do {
                        try manager.connection.startVPNTunnel()
                        VulcainLogger.log("MainApp", "startVPNTunnel() called successfully")
                        result(true)
                    } catch {
                        VulcainLogger.error("MainApp", "startVPNTunnel() threw: \(error.localizedDescription)")
                        result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    // MARK: - Stop

    private func stopVpn(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            guard let manager = managers?.first else {
                result(nil)
                return
            }
            manager.connection.stopVPNTunnel()
            result(nil)
        }
    }

    // MARK: - Status observation -> event channel

    private func observeStatus(manager: NETunnelProviderManager) {
        if let existing = statusObserver {
            NotificationCenter.default.removeObserver(existing)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            self?.emitStatus(manager.connection.status)
        }
    }

    private func emitStatus(_ status: NEVPNStatus) {
        VulcainLogger.log("MainApp", "NEVPNStatus changed: \(status.rawValue)")
        guard let sink = eventSink else { return }

        switch status {
        case .connected:
            sink(["event": "connected", "message": "Connected"])
        case .disconnected:
            sink(["event": "disconnected", "message": "Disconnected"])
        case .disconnecting:
            sink(["event": "disconnected", "message": "Disconnecting"])
        case .invalid, .reasserting:
            // "invalid" often means the extension crashed or the config
            // file couldn't be read — surface as died, not a silent
            // no-op, or you'll get another white-screen-style dead end
            // with no signal.
            sink(["event": "vpn_died", "reason": "invalid_state", "message": "VPN entered an invalid state"])
        case .connecting:
            break // No Flutter-side handling needed for transient state yet
        @unknown default:
            break
        }
    }
}

extension VpnManager: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
