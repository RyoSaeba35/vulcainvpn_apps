import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';
import 'vpn_service_android.dart'; // Reuses VpnEvent / VpnEventType

/// macOS VPN service — talks to VpnManager.swift via a System Extension
/// (NEPacketTunnelProvider), NOT by spawning a sing-box subprocess.
///
/// This replaces the earlier subprocess-based implementation. That
/// approach is no longer viable now that Runner's entitlements have
/// app-sandbox=true (required for the System Extension architecture —
/// sandboxed apps can't spawn arbitrary bundled executables the way the
/// old approach did).
///
/// Structurally mirrors vpn_service_ios.dart, since both now go through
/// NETunnelProviderManager-style native code. The one macOS-specific step
/// with no iOS equivalent is activateExtensionIfNeeded() — macOS's System
/// Extension framework requires an explicit one-time user approval flow
/// (System Settings → Login Items & Extensions) before the extension can
/// be used at all.
class MacosVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/macos_control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/macos_status');

  static final StreamController<VpnEvent> _eventController =
      StreamController<VpnEvent>.broadcast();

  static void setupEventListener() {
    _statusChannel.receiveBroadcastStream().listen((event) {
      print('📡 [macOS] Received status event from native: $event');
      if (event is bool) {
        _eventController.add(VpnEvent(
          type: event ? VpnEventType.connected : VpnEventType.disconnected,
          message: event ? 'Connected' : 'Disconnected',
        ));
      }
    }, onError: (error) {
      print('❌ [macOS] Event stream error: $error');
    });
  }

  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) => e as bool);

  /// Must succeed before startVpn will work. Triggers the macOS system
  /// approval prompt on first run — see VpnManager.swift for details.
  /// Safe to call every time before startVpn(); once approved, this
  /// resolves quickly on subsequent calls.
  Future<bool> activateExtensionIfNeeded() async {
    try {
      final result = await _platform.invokeMethod('activateExtensionIfNeeded');
      print('✅ [macOS] Extension activation result: $result');
      return result == true;
    } on PlatformException catch (e) {
      print('❌ [macOS] Extension activation failed: ${e.code} - ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> startVpn() async {
    try {
      final activated = await activateExtensionIfNeeded();
      if (!activated) {
        throw Exception(
          'System Extension not activated. Check System Settings > '
          'Login Items & Extensions > Network Extensions and approve VulcainVPN.',
        );
      }

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('❌ [macOS] Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      print('🔵 [macOS] Calling API for device: $deviceId');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode == 401) {
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Device not registered. Please login again.');
      }

      if (response.statusCode == 403) {
        final errorData = json.decode(response.body);
        throw Exception(
          '${errorData['error'] ?? 'No active subscription'}|'
          'renewal_url:${errorData['renewal_url'] ?? 'https://www.vulcainvpn.com/dashboard'}',
        );
      }

      if (response.statusCode == 429) {
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Maximum active devices reached. Please disconnect another device first.');
      }

      if (response.statusCode == 503) {
        final errorData = json.decode(response.body);
        throw Exception('TECHNICAL_ISSUE|${errorData['message'] ?? 'We\'re experiencing technical difficulties. Please try again shortly.'}');
      }

      if (response.statusCode != 200) {
        try {
          final errorData = json.decode(response.body);
          throw Exception(errorData['message'] ?? 'Failed to connect: ${response.statusCode}');
        } catch (_) {
          throw Exception('Failed to connect: ${response.statusCode}');
        }
      }

      final data = json.decode(response.body);
      final credentials = data['credentials'];

      if (credentials == null || credentials['wireguard'] == null) {
        throw Exception('Maximum active devices reached. Please disconnect another device first.');
      }

      print('✅ [macOS] Credentials received');

      final config = await VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      print('✅ [macOS] Config built (${configJson.length} chars)');

      final result = await _platform.invokeMethod('startVpn', {
        'config': configJson,
      });

      print('✅ [macOS] VPN start requested successfully');
      return result == true;
    } on PlatformException catch (e) {
      print('❌ [macOS] PlatformException: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      print('❌ [macOS] Error: $e');
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
        print('✅ [macOS] Backend notified of disconnection');
      }
    } catch (e) {
      print('⚠️ [macOS] Failed to notify backend: $e');
    }

    await _platform.invokeMethod('stopVpn');
  }

  @override
  Future<bool> checkNotificationPermission() async {
    // macOS notification permission is handled separately via
    // MacosNotificationService / flutter_local_notifications — no
    // native round-trip needed here the way Android's is.
    return true;
  }

  @override
  Future<VpnEvent?> checkForDeathEvents() async {
    // No native "stored death event" mechanism on macOS yet (unlike
    // Android/iOS). The statusStream / EventChannel is the live signal;
    // this is a no-op placeholder to satisfy the VpnService contract.
    return null;
  }

  @override
  Future<String> checkSubscription() async {
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) return 'unknown';

      final response = await http.get(
        Uri.parse('https://api.vulcainvpn.com/api/subscription'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['subscription']['status'] as String;
        return status != 'active' ? 'expired' : 'active';
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        return 'expired';
      }
      return 'unknown';
    } catch (e) {
      print('❌ [macOS] Error checking subscription: $e');
      return 'unknown';
    }
  }

  @override
  Future<void> reconnectVpn() async {
    try {
      final subscriptionStatus = await checkSubscription();

      if (subscriptionStatus == 'expired') {
        throw Exception('subscription_expired');
      }

      await startVpn();
    } catch (e) {
      print('❌ [macOS] Reconnect failed: $e');
      rethrow;
    }
  }
}
