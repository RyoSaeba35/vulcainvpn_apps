import 'dart:io';
import 'vpn_service_android.dart';
import 'vpn_service_windows.dart';

abstract class VpnService {
  static VpnService get instance {
    if (Platform.isAndroid) return AndroidVpnService();
    if (Platform.isWindows) return WindowsVpnService();
    throw UnsupportedError('Platform not supported');
  }

  Stream<bool> get statusStream;
  Future<bool> startVpn();
  Future<void> stopVpn();
  Future<bool> checkNotificationPermission();
  Future<String> checkSubscription();
  Future<void> reconnectVpn();
  Future<VpnEvent?> checkForDeathEvents();
}
