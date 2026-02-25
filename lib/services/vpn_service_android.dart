import 'package:flutter/services.dart';
import 'vpn_service.dart';

class AndroidVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/status');

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) => e as bool);

  @override
  Future<bool> startVpn() async => await _platform.invokeMethod('startVpn');

  @override
  Future<void> stopVpn() async => await _platform.invokeMethod('stopVpn');

  @override
  Future<bool> checkNotificationPermission() async =>
      await _platform.invokeMethod('checkNotificationPermission'); // ← was missing
}
