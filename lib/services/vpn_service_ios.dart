import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';
import 'location_service.dart';
import 'language_service.dart';
import 'trial_notice.dart';
import 'vpn_service_android.dart'; // Reuses VpnEvent / VpnEventType

class IosVpnService extends VpnService {
  static const MethodChannel _platform = MethodChannel('com.vulcain.vpn/ios_control');
  static const EventChannel _statusChannel = EventChannel('com.vulcain.vpn/ios_status');

  static final StreamController<VpnEvent> _eventController =
      StreamController<VpnEvent>.broadcast();

  static void setupEventListener() {
    _statusChannel.receiveBroadcastStream().listen((event) {
      print('📡 [iOS] Received event from native: $event');

      if (event is Map) {
        final eventType = event['event'] as String?;
        final reason = event['reason'] as String?;
        final message = event['message'] as String?;

        if (eventType == 'vpn_died') {
          _eventController.add(VpnEvent(
            type: VpnEventType.died,
            reason: reason ?? 'unknown',
            message: message ?? 'VPN disconnected unexpectedly',
          ));
        } else if (eventType == 'connected') {
          _eventController.add(VpnEvent(
            type: VpnEventType.connected,
            message: message ?? 'Connected',
          ));
        } else if (eventType == 'disconnected') {
          _eventController.add(VpnEvent(
            type: VpnEventType.disconnected,
            message: message ?? 'Disconnected',
          ));
        } else if (eventType == 'error') {
          _eventController.add(VpnEvent(
            type: VpnEventType.error,
            message: message ?? 'Error',
          ));
        }
      }
    }, onError: (error) {
      print('❌ [iOS] Event stream error: $error');
    });
  }

  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream => _statusChannel.receiveBroadcastStream().map((e) {
        if (e is Map) {
          final eventType = e['event'] as String?;
          return eventType == 'connected';
        }
        return e as bool;
      });

  @override
  Future<bool> startVpn() async {
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        print('❌ [iOS] Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      print('🔵 [iOS] Calling API for device: $deviceId');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey, 'Content-Type': 'application/json', ...LanguageService.headers},
        // "auto" or a country code chosen in the location picker
        body: await LocationService.connectBody(),
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

      if (response.statusCode == 409) {
        // The chosen country can't take the connection (coming soon, full...)
        final errorData = json.decode(response.body);
        throw Exception('${LocationService.unavailableErrorPrefix}${errorData['message'] ?? 'This location is not available right now.'}');
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
      LocationService.rememberConnectedServer(Map<String, dynamic>.from(data as Map));
      TrialNotice.rememberFromConnect(Map<String, dynamic>.from(data));
      final credentials = data['credentials'];

      if (credentials == null || credentials['wireguard'] == null) {
        throw Exception('Maximum active devices reached. Please disconnect another device first.');
      }

      print('✅ [iOS] Credentials received');

      final config = await VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      print('✅ [iOS] Config built (${configJson.length} chars)');

      final accessToken = await AuthService.getValidAccessToken();
      if (accessToken == null) {
        throw Exception('Authentication required - please login again');
      }

      // Native side handles NETunnelProviderManager: loads/creates the VPN
      // profile, stashes configJson into providerConfiguration, and calls
      // connection.startVPNTunnel(). This is fundamentally different from
      // Android — iOS doesn't run sing-box in the main process at all, it
      // hands off to the PacketTunnel extension.
      final result = await _platform.invokeMethod('startVpn', {
        'config': configJson,
        'access_token': accessToken,
        'server_address': credentials['wireguard']['server_ip'],
      });

      print('✅ [iOS] VPN start requested successfully');
      return result == true;
    } on PlatformException catch (e) {
      print('❌ [iOS] PlatformException: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      print('❌ [iOS] Error: $e');
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
        print('✅ [iOS] Backend notified of disconnection');
      }
    } catch (e) {
      print('⚠️ [iOS] Failed to notify backend: $e');
    }

    await _platform.invokeMethod('stopVpn');
  }

  @override
  Future<bool> checkNotificationPermission() async {
    try {
      return await _platform.invokeMethod('checkNotificationPermission');
    } catch (e) {
      return false;
    }
  }

  @override
  Future<VpnEvent?> checkForDeathEvents() async {
    try {
      final result = await _platform.invokeMethod('checkForDeathEvents');

      if (result != null && result is Map) {
        return VpnEvent(
          type: VpnEventType.died,
          reason: result['reason'] as String?,
          message: result['message'] as String,
          timestamp: result['timestamp'] as int?,
        );
      }
      return null;
    } catch (e) {
      print('❌ [iOS] Error checking death events: $e');
      return null;
    }
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
      print('❌ [iOS] Error checking subscription: $e');
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
      print('❌ [iOS] Reconnect failed: $e');
      rethrow;
    }
  }
}
