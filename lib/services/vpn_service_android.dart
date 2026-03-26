import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';

class AndroidVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/status');

  // ⭐ Helper to show toast messages
  void _showToast(String message) {
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      backgroundColor: Colors.black87,
      textColor: Colors.white,
      fontSize: 14.0,
    );
  }

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) => e as bool);

  @override
  Future<bool> startVpn() async {
    try {
      // Step 1: Get credentials
      print('🔵 Step 1: Getting credentials...');
      _showToast('Step 1: Getting credentials...');

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('❌ Device not registered');
        print('   deviceId: $deviceId');
        print('   apiKey: ${apiKey?.substring(0, 16)}...');
        _showToast('❌ Device not registered');
        return false;
      }

      // Step 2: Call API
      print('🔵 Step 2: Calling API...');
      _showToast('Step 2: Calling API...');
      print('   Device ID: $deviceId');
      print('   URL: https://api.vulcainvpn.com/api/connect/$deviceId');
      _showToast('Device: ${deviceId.substring(0, 10)}...');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      print('🔵 API Response: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ API error: ${response.statusCode}');
        print('   Body: ${response.body}');
        _showToast('❌ API error: ${response.statusCode}');
        return false;
      }

      // Step 3: Build config
      print('🔵 Step 3: Building config...');
      _showToast('Step 3: Building config...');

      final data = json.decode(response.body);
      final credentials = data['credentials'];

      print('   WireGuard credentials:');
      print('     server_ip: ${credentials['wireguard']['server_ip']}');
      print('     server_port: ${credentials['wireguard']['server_port']}');
      print('     client_ip: ${credentials['wireguard']['client_ip']}');
      print('     PSK present: ${credentials['wireguard']['client_preshared_key'] != null}');

      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      print('✅ Config built (${configJson.length} chars)');

      // ⭐ ADD THIS: Save first 500 chars to debug string
      VpnConfigService.lastDebugInfo += '\n\n📄 Config Preview:\n' +
          configJson.substring(0, configJson.length > 500 ? 500 : configJson.length);

      print('🔧 Full config:\n$configJson');  // ⭐ Print full config to logs

      // Validate config size
      if (configJson.length > 100000) {
        print('⚠️  WARNING: Config is very large: ${configJson.length} chars');
      }

      // Step 4: Call native Android
      print('🔵 Step 4: Calling native Android...');
      _showToast('Step 4: Calling native Android...');

      final result = await _platform.invokeMethod('startVpn', {
        'config': configJson,
      });

      print('✅ Native returned: $result');
      _showToast('✅ Native code reached!');
      return result;

    } on PlatformException catch (e) {
      print('❌ PlatformException: ${e.code}');
      print('   Message: ${e.message}');
      print('   Details: ${e.details}');
      _showToast('❌ Platform error: ${e.code}');
      rethrow; // Re-throw so UI can show the error
    } catch (e, stackTrace) {
      print('❌ Unexpected error: $e');
      print('   Stack: ${stackTrace.toString().split('\n').take(5).join('\n')}');
      _showToast('❌ Error: ${e.toString().substring(0, 50)}...');
      rethrow; // Re-throw so UI can show the error
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
