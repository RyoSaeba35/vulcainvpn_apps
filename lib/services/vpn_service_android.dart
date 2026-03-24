import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';

class AndroidVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/status');

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) => e as bool);

  @override
  Future<bool> startVpn() async {
    try {
      // ⭐ Step 1: Get device credentials
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('Error: Device not registered');
        return false;
      }

      print('Fetching credentials for device: $deviceId');

      // ⭐ Step 2: Call /api/connect to get credentials
      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode != 200) {
        print('Failed to get credentials: ${response.statusCode}');
        return false;
      }

      final data = json.decode(response.body);
      final credentials = data['credentials'];
      print('Credentials received');

      // ⭐ Step 3: Build dynamic config
      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      // ⭐ Step 4: Convert to JSON string
      final configJson = VpnConfigService.toJsonString(config);
      print('Config built successfully');

      // ⭐ Step 5: Pass config to native Android code
      return await _platform.invokeMethod('startVpn', {
        'config': configJson,  // Pass the dynamic config
      });
    } catch (e) {
      print('Android VPN error: $e');
      return false;
    }
  }

  @override
  Future<void> stopVpn() async {
    // ⭐ Notify backend of disconnection
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId != null && apiKey != null) {
        await http.post(
          Uri.parse('https://api.vulcainvpn.com/api/disconnect/$deviceId'),
          headers: {'X-Api-Key': apiKey},
        );
        print('Backend notified of disconnection');
      }
    } catch (e) {
      print('Failed to notify backend: $e');
    }

    await _platform.invokeMethod('stopVpn');
  }

  @override
  Future<bool> checkNotificationPermission() async =>
      await _platform.invokeMethod('checkNotificationPermission');
}
