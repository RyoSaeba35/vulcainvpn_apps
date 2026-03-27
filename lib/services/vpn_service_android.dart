import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';

class AndroidVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/status');

  // ⭐ NEW: Health check timer
  Timer? _healthCheckTimer;
  final _statusController = StreamController<bool>.broadcast();

  @override
  Stream<bool> get statusStream => _statusController.stream;

  // ⭐ NEW: Start periodic health checks
  void startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final actualState = await checkVpnState();
      _statusController.add(actualState);
    });
  }

  // ⭐ NEW: Stop health checks
  void stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  @override
  Future<bool> startVpn() async {
    try {
      // Get credentials
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('❌ Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      print('🔵 Calling API for device: $deviceId');

      // Call API
      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode == 429) {
        print('❌ Maximum devices reached');
        throw Exception('Maximum active devices reached. Please disconnect another device first.');
      }

      if (response.statusCode != 200) {
        print('❌ API error: ${response.statusCode}');
        print('   Body: ${response.body}');
        throw Exception('Failed to connect: ${response.statusCode}');
      }

      // Parse credentials
      final data = json.decode(response.body);
      final credentials = data['credentials'];

      if (credentials['wireguard'] == null) {
        print('❌ No WireGuard credentials available (all slots in use)');
        throw Exception('Maximum active devices reached. Please disconnect another device first.');
      }

      print('✅ Credentials received');

      // Build config
      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      print('✅ Config built (${configJson.length} chars)');

      final result = await _platform.invokeMethod('startVpn', {
        'config': configJson,
        'device_id': deviceId,
        'api_key': apiKey,
      });

      print('✅ VPN started successfully');

      // ⭐ Start health monitoring
      startHealthCheck();

      return result;

    } on PlatformException catch (e) {
      print('❌ PlatformException: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      print('❌ Error: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopVpn() async {
    // ⭐ Stop health checks first
    stopHealthCheck();

    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId != null && apiKey != null) {
        await http.post(
          Uri.parse('https://api.vulcainvpn.com/api/disconnect/$deviceId'),
          headers: {'X-Api-Key': apiKey},
        );
        print('✅ Backend notified of disconnection');
      }
    } catch (e) {
      print('⚠️  Failed to notify backend: $e');
    }

    await _platform.invokeMethod('stopVpn');
    _statusController.add(false);
  }

  @override
  Future<bool> checkNotificationPermission() async =>
      await _platform.invokeMethod('checkNotificationPermission');

  // ⭐ Check actual VPN state from native side
  Future<bool> checkVpnState() async {
    try {
      final result = await _platform.invokeMethod('getStatus');
      return result as bool;
    } catch (e) {
      print('Failed to check VPN state: $e');
      return false;
    }
  }

  Future<int?> getConnectionStartTimeMs() async {
    try {
      return await _platform.invokeMethod('getStartTime');
    } catch (e) {
      return null;
    }
  }

  // ⭐ NEW: Clean up on dispose
  void dispose() {
    stopHealthCheck();
    _statusController.close();
  }
}
