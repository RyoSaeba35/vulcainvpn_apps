import Foundation
import NetworkExtension
import SystemExtensions
import FlutterMacOS

/// VpnManager — macOS main-app-side VPN control, bridged to Flutter.
///
/// UNLIKE iOS, macOS needs an extra activation step before the tunnel
/// extension can be used at all: OSSystemExtensionRequest. This has no
/// iOS equivalent (iOS app extensions are just loaded automatically by
/// NETunnelProviderManager) — it's the macOS System Extension framework's
/// own approval flow, confirmed as required for Developer ID distribution
/// per Apple DTS earlier this session.
///
/// This file was NOT ported from an iOS VpnManager.swift (none was
/// provided) — written from documented OSSystemExtensionRequest /
/// NETunnelProviderManager APIs, and from the MethodChannel/EventChannel
/// naming convention already established in lib/services/vpn_service_ios.dart.
/// This part is comparatively lower-risk than PacketTunnelProvider.swift's
/// Libbox bridging, since these are standard, well-documented Apple APIs
/// rather than gomobile-generated bindings with hidden renames.
class VpnManager: NSObject {

    static let shared = VpnManager()

    private let extensionBundleID = "com.vulcainvpn.app.macos.PacketTunnel"
    private let appGroup = "group.com.vulcainvpn.app.macos"

    private var eventSink: FlutterEventSink?
    private var activationContinuation: ((Result<Void, Error>) -> Void)?

    // MARK: - Flutter channel setup

    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.vulcain.vpn/macos_control",
            binaryMessenger: registrar.messenger
        )
        let statusChannel = FlutterEventChannel(
            name: "com.vulcain.vpn/macos_status",
            binaryMessenger: registrar.messenger
        )

        statusChannel.setStreamHandler(shared)

        methodChannel.setMethodCallHandler { call, result in
            switch call.method {
            case "activateExtensionIfNeeded":
                shared.activateExtensionIfNeeded { activationResult in
                    switch activationResult {
                    case .success:
                        result(true)
                    case .failure(let error):
                        result(FlutterError(code: "ACTIVATION_FAILED", message: error.localizedDescription, details: nil))
                    }
                }
            case "startVpn":
                guard let args = call.arguments as? [String: Any],
                      let config = args["config"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "Missing config", details: nil))
                    return
                }
                shared.startVpn(config: config) { startResult in
                    switch startResult {
                    case .success:
                        result(true)
                    case .failure(let error):
                        result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
                    }
                }
            case "stopVpn":
                shared.stopVpn { result(true) }
            case "checkVpnStatus":
                result(shared.currentStatusString())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - System Extension activation

    /// Must be called (and succeed) before startVpn will work. Triggers
    /// the macOS "System software from developer X was blocked" /
    /// approval prompt on first run — user must go approve it manually in
    /// System Settings → Login Items & Extensions → Network Extensions
    /// (per the DTS guidance found earlier this session; there is no way
    /// to skip or auto-approve this from the app).
    func activateExtensionIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        activationContinuation = completion
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        VulcainLogger.log("MainApp", "OSSystemExtensionRequest submitted for \(extensionBundleID)")
    }

    // MARK: - Tunnel control

    func startVpn(config: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard writeConfigToAppGroup(config) else {
            completion(.failure(NSError(domain: "VulcainVPN", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write config to App Group container"])))
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }

            let manager = managers?.first ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.extensionBundleID
            proto.serverAddress = "VulcainVPN" // display-only, not a real host

            manager.protocolConfiguration = proto
            manager.localizedDescription = "VulcainVPN"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    completion(.failure(saveError))
                    return
                }

                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        completion(.failure(loadError))
                        return
                    }

                    do {
                        try manager.connection.startVPNTunnel()
                        VulcainLogger.log("MainApp", "startVPNTunnel() called successfully")
                        completion(.success(()))
                    } catch {
                        VulcainLogger.error("MainApp", "startVPNTunnel() threw: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func stopVpn(completion: @escaping () -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            managers?.first?.connection.stopVPNTunnel()
            VulcainLogger.log("MainApp", "stopVPNTunnel() called")
            completion()
        }
    }

    private func currentStatusString() -> String {
        // Best-effort synchronous snapshot for a simple status check —
        // for the live-updating case, use the EventChannel stream instead.
        NEVPNManager.shared().connection.status.description
    }

    // MARK: - Config sharing (App Group)

    private func writeConfigToAppGroup(_ config: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            VulcainLogger.error("MainApp", "could not access App Group container \(appGroup)")
            return false
        }
        let configURL = containerURL.appendingPathComponent("vpn_config.json")
        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            VulcainLogger.log("MainApp", "wrote config to App Group container (\(config.count) chars)")
            return true
        } catch {
            VulcainLogger.error("MainApp", "failed writing config: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - VPN status observation → Flutter EventChannel

    private func observeStatus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc private func statusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        let isConnected = connection.status == .connected
        eventSink?(isConnected)
    }

    override init() {
        super.init()
        observeStatus()
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension VpnManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        VulcainLogger.log("MainApp", "System Extension activation finished: \(result == .completed ? "completed" : "will complete after reboot")")
        activationContinuation?(.success(()))
        activationContinuation = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        VulcainLogger.error("MainApp", "System Extension activation failed: \(error.localizedDescription)")
        activationContinuation?(.failure(error))
        activationContinuation = nil
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // This is the "go approve it in System Settings" moment — no
        // programmatic way to skip it. The completion handler is NOT
        // called here; didFinishWithResult fires later once the user
        // actually approves it in System Settings.
        VulcainLogger.log("MainApp", "System Extension needs user approval — check System Settings > Login Items & Extensions > Network Extensions")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Always allow replacing an older installed version with this build.
        return .replace
    }
}

// MARK: - FlutterStreamHandler (status EventChannel)

extension VpnManager: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

private extension NEVPNStatus {
    var description: String {
        switch self {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .invalid: return "invalid"
        case .reasserting: return "reasserting"
        @unknown default: return "unknown"
        }
    }
}
