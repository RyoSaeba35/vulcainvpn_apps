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

  // ✅ PRIORITY 1: New stream controller for VPN events
  static final StreamController<VpnEvent> _eventController = StreamController<VpnEvent>.broadcast();

  // ✅ PRIORITY 1: Setup event listener (call this once at app startup)
  static void setupEventListener() {
    _statusChannel.receiveBroadcastStream().listen((event) {
      print('📡 Received event from native: $event');

      if (event is Map) {
        // ✅ New format: Map with event details
        final eventType = event['event'] as String?;
        final reason = event['reason'] as String?;
        final message = event['message'] as String?;

        print('📡 Event type: $eventType, reason: $reason');

        if (eventType == 'vpn_died') {
          // ✅ VPN died unexpectedly!
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
      } else if (event is bool) {
        // ✅ Old format: Simple bool (for backward compatibility)
        print('📡 Received legacy bool event: $event');
        _eventController.add(VpnEvent(
          type: event ? VpnEventType.connected : VpnEventType.disconnected,
          message: event ? 'Connected' : 'Disconnected',
        ));
      }
    }, onError: (error) {
      print('❌ Event stream error: $error');
    });
  }

  // ✅ PRIORITY 1: Expose event stream
  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream =>
      _statusChannel.receiveBroadcastStream().map((e) {
        // Map events to bool for backward compatibility
        if (e is Map) {
          final eventType = e['event'] as String?;
          return eventType == 'connected';
        }
        return e as bool;
      });

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

  // ✅ PRIORITY 1: IMPROVED - Actually verify VPN is running
  Future<bool> checkVpnState() async {
    try {
      // Step 1: Check SharedPreferences
      final isRunningInPrefs = await _platform.invokeMethod('getStatus') as bool;

      if (!isRunningInPrefs) {
        print('✅ SharedPrefs says VPN not running');
        return false;  // Definitely not running
      }

      print('🔍 SharedPrefs says running, verifying actual VPN state...');

      // Step 2: ✅ NEW - Actually verify VPN interface is active
      final isActuallyActive = await _platform.invokeMethod('isVpnActive') as bool;

      if (!isActuallyActive) {
        // SharedPrefs says running but VPN is actually dead!
        print('⚠️ MISMATCH DETECTED! SharedPrefs says running but VPN is dead!');
        print('🧹 Clearing stale state...');

        // Clear the stale state
        await _platform.invokeMethod('clearVpnState');

        // ✅ PRIORITY 1: Send "died" event to UI
        _eventController.add(VpnEvent(
          type: VpnEventType.died,
          reason: 'state_mismatch',
          message: 'VPN was disconnected while app was closed',
        ));

        return false;
      }

      print('✅ VPN is actually running');
      return true;

    } catch (e) {
      print('❌ Failed to check VPN state: $e');
      return false;
    }
  }

  // ✅ NEW: Direct network check - bypasses SharedPreferences
  Future<bool> isVpnActive() async {
    try {
      final isActive = await _platform.invokeMethod('isVpnActive') as bool;
      print('🔍 VPN network check: $isActive');
      return isActive;
    } catch (e) {
      print('❌ Failed to check VPN active state: $e');
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

  // ✅ PRIORITY 1: Check for stored death events (when app resumes)
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
      print('❌ Error checking death events: $e');
      return null;
    }
  }

  // ✅ PRIORITY 3: Check subscription status
  @override
  Future<String> checkSubscription() async {
    try {
      print('🔍 Checking subscription status...');
      final result = await _platform.invokeMethod('checkSubscription');
      final status = result as String; // 'active', 'expired', or 'unknown'
      print('📡 Subscription status: $status');
      return status;
    } catch (e) {
      print('❌ Error checking subscription: $e');
      return 'unknown';
    }
  }

  // ✅ PRIORITY 3: Reconnect with subscription check
  @override
  Future<void> reconnectVpn() async {
    try {
      // CRITICAL: Check subscription FIRST
      print('🔍 Checking subscription before reconnect...');
      final subscriptionStatus = await checkSubscription();

      if (subscriptionStatus == 'expired') {
        print('❌ Subscription expired - blocking reconnect');
        throw Exception('subscription_expired');
      }

      if (subscriptionStatus == 'active') {
        print('✅ Subscription active - proceeding with reconnect');
      } else {
        print('⚠️ Could not verify subscription - allowing reconnect attempt');
      }

      // Subscription is OK - proceed with normal connection
      await startVpn();

    } catch (e) {
      print('❌ Reconnect failed: $e');
      rethrow;
    }
  }
}

// ✅ PRIORITY 1: VPN Event types
enum VpnEventType {
  connected,
  disconnected,
  died,      // ← NEW! VPN died unexpectedly
  error,
}

// ✅ PRIORITY 1: VPN Event class
class VpnEvent {
  final VpnEventType type;
  final String? reason;
  final String message;
  final int? timestamp;

  VpnEvent({
    required this.type,
    this.reason,
    required this.message,
    this.timestamp,
  });

  @override
  String toString() => 'VpnEvent(type: $type, reason: $reason, message: $message)';
}
