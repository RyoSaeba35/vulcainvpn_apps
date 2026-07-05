import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      fatalError("rootViewController is not FlutterViewController")
    }

    let methodChannel = FlutterMethodChannel(
      name: "com.vulcain.vpn/ios_control",
      binaryMessenger: controller.binaryMessenger
    )
    let eventChannel = FlutterEventChannel(
      name: "com.vulcain.vpn/ios_status",
      binaryMessenger: controller.binaryMessenger
    )

    VpnManager.shared.setup(methodChannel: methodChannel, eventChannel: eventChannel)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
