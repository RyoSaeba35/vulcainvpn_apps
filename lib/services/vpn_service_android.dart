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

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) => e as bool);

  @override
  Future<bool> startVpn() async {
    try {
      // Get credentials for API call
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('❌ Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      print('🔵 Calling API for device: $deviceId');

      // Call /connect API
      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      // ✅ NEW: Handle different status codes with proper error messages
      if (response.statusCode == 401) {
        print('❌ Unauthorized (401)');
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Device not registered. Please login again.');
      }

      if (response.statusCode == 403) {
        print('❌ Forbidden - No active subscription (403)');
        final errorData = json.decode(response.body);
        // Include renewal URL in exception for frontend to parse
        throw Exception(
          '${errorData['error'] ?? 'No active subscription'}|'
          'renewal_url:${errorData['renewal_url'] ?? 'https://www.vulcainvpn.com/dashboard'}'
        );
      }

      if (response.statusCode == 429) {
        print('❌ Too Many Requests - Device limit (429)');
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Maximum active devices reached. Please disconnect another device first.');
      }

      if (response.statusCode != 200) {
        print('❌ API error: ${response.statusCode}');
        print('   Body: ${response.body}');

        // Try to parse error message from response
        try {
          final errorData = json.decode(response.body);
          throw Exception(errorData['message'] ?? 'Failed to connect: ${response.statusCode}');
        } catch (_) {
          throw Exception('Failed to connect: ${response.statusCode}');
        }
      }

      // ✅ Parse credentials from new response format
      final data = json.decode(response.body);
      final credentials = data['credentials'];

      if (credentials == null) {
        print('❌ No credentials in response');
        throw Exception('Failed to get connection credentials');
      }

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

      // Start VPN with config
      final result = await _platform.invokeMethod('startVpn', {
        'config': configJson,
      });

      print('✅ VPN started successfully');
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
  }

  @override
  Future<bool> checkNotificationPermission() async =>
      await _platform.invokeMethod('checkNotificationPermission');

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
}
