import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Registers com.vulcain.vpn/macos_control (MethodChannel) and
    // com.vulcain.vpn/macos_status (EventChannel) — see VpnManager.swift.
    let registrar = flutterViewController.registrar(forPlugin: "VpnManager")
    VpnManager.register(with: registrar)

    super.awakeFromNib()
  }
}
