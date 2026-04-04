import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';
import 'secure_config_service.dart';
import 'vpn_service_android.dart'; // For VpnEvent types

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;
  static bool _isNormalStop = false; // ✅ Track if disconnect was intentional

  static String? _configPath;
  static String? _plaintextPath;

  // ✅ PRIORITY 1: Process checker timer
  static Timer? _processChecker;
  static final StreamController<VpnEvent> _eventController = StreamController<VpnEvent>.broadcast();

  // ✅ PRIORITY 2: Heartbeat monitoring
  static Timer? _heartbeatTimer;
  static int _consecutiveFailures = 0;
  static DateTime? _lastSuccessfulPing;
  static const int _heartbeatIntervalSeconds = 10;
  static const int _maxConsecutiveFailures = 3; // 30 seconds total
  static const String _pingHost = '1.1.1.1'; // Cloudflare DNS

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;
  static String get _logPath => '$_exeDir\\vpn_log.txt';

  static Future<void> _log(String message) async {
    final logFile = File(_logPath);
    if (await logFile.exists()) {
      final size = await logFile.length();
      if (size > 1024 * 1024) {
        await logFile.rename('$_exeDir\\vpn_log_old.txt');
      }
    }
    final timestamp = DateTime.now().toIso8601String();
    await logFile.writeAsString('$timestamp: $message\n', mode: FileMode.append);
  }

  static String get _singBoxPath {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    final arch2 = Platform.environment['PROCESSOR_ARCHITEW6432'] ?? '';
    final isArm = arch.toUpperCase().contains('ARM') ||
                  arch2.toUpperCase().contains('ARM');

    final binary = isArm ? 'sing-box-arm64.exe' : 'sing-box-amd64.exe';
    return '$_exeDir\\$binary';
  }

  // ✅ PRIORITY 1: Expose event stream
  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream => _statusController.stream;

  // ✅ PRIORITY 1: Start process checker (checks if sing-box is running)
  static void _startProcessChecker() {
    _processChecker?.cancel();

    _processChecker = Timer.periodic(Duration(seconds: 3), (timer) async {
      if (!_isConnected) {
        timer.cancel();
        return;
      }

      final isRunning = await _isSingBoxRunning();

      if (!isRunning && _isConnected) {
        // ✅ Only send death event if NOT a normal stop
        if (!_isNormalStop) {
          await _log('⚠️ sing-box process died unexpectedly!');

          _isConnected = false;
          _statusController.add(false);

          // Send death event
          _eventController.add(VpnEvent(
            type: VpnEventType.died,
            reason: 'process_crashed',
            message: 'VPN process crashed unexpectedly',
          ));
        }

        timer.cancel();
      }
    });
  }

  // ✅ PRIORITY 1: Stop process checker
  static void _stopProcessChecker() {
    _processChecker?.cancel();
    _processChecker = null;
  }

  // ✅ PRIORITY 1: Check if sing-box process is running
  static Future<bool> _isSingBoxRunning() async {
    try {
      // Check for amd64 version
      final result1 = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq sing-box-amd64.exe', '/NH'],
      );

      if (result1.stdout.toString().contains('sing-box-amd64.exe')) {
        return true;
      }

      // Check for arm64 version
      final result2 = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq sing-box-arm64.exe', '/NH'],
      );

      if (result2.stdout.toString().contains('sing-box-arm64.exe')) {
        return true;
      }

      return false;
    } catch (e) {
      await _log('Error checking process: $e');
      return false;
    }
  }

  // ✅ PRIORITY 2: Start heartbeat monitoring
  static void _startHeartbeatMonitoring() {
    _stopHeartbeatMonitoring(); // Cancel any existing timer

    _log('💓 Starting heartbeat monitoring (every ${_heartbeatIntervalSeconds}s)');
    _consecutiveFailures = 0;
    _lastSuccessfulPing = DateTime.now();

    _heartbeatTimer = Timer.periodic(
      Duration(seconds: _heartbeatIntervalSeconds),
      (timer) async {
        if (!_isConnected) {
          timer.cancel();
          return;
        }

        try {
          final isReachable = await _performHeartbeatCheck();

          if (isReachable) {
            // ✅ Ping successful
            if (_consecutiveFailures > 0) {
              await _log('💚 Heartbeat recovered after $_consecutiveFailures failures');
            }
            _consecutiveFailures = 0;
            _lastSuccessfulPing = DateTime.now();
          } else {
            // ❌ Ping failed
            _consecutiveFailures++;
            final timeSinceLastSuccess = DateTime.now().difference(_lastSuccessfulPing!).inSeconds;

            await _log('💔 Heartbeat failed ($_consecutiveFailures/$_maxConsecutiveFailures) - Last success: ${timeSinceLastSuccess}s ago');

            if (_consecutiveFailures >= _maxConsecutiveFailures) {
              // Multiple failures detected
              await _handleHeartbeatFailure();
            }
          }
        } catch (e) {
          await _log('Heartbeat check error: $e');
        }
      },
    );
  }

  // ✅ PRIORITY 2: Stop heartbeat monitoring
  static void _stopHeartbeatMonitoring() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _consecutiveFailures = 0;
    _log('💓 Stopped heartbeat monitoring');
  }

  // ✅ PRIORITY 2: Perform heartbeat check
  static Future<bool> _performHeartbeatCheck() async {
    try {
      // Use ping command to check internet connectivity
      final result = await Process.run(
        'ping',
        ['-n', '1', '-w', '3000', _pingHost], // 1 ping, 3 second timeout
      );

      final success = result.exitCode == 0;

      if (success) {
        await _log('💚 Ping OK: $_pingHost');
      } else {
        await _log('💔 Ping FAILED: $_pingHost');
      }

      return success;
    } catch (e) {
      await _log('💔 Ping exception: $e');
      return false;
    }
  }

  // ✅ PRIORITY 2: Handle heartbeat failure - SMART detection
  static Future<void> _handleHeartbeatFailure() async {
    await _log('🚨 HEARTBEAT FAILURE DETECTED!');
    await _log('   VPN is connected but no internet access through VPN');
    await _log('   3 consecutive ping failures detected');

    // ✅ SMART: Check if device has ANY network at all
    final hasAnyNetwork = await _checkForAnyNetwork();

    if (!hasAnyNetwork) {
      // No network adapters active at all
      // User may be in tunnel, airplane mode, or network is down
      // DON'T stop VPN - just wait for network to return
      await _log('📶 NO NETWORK DETECTED');
      await _log('   User may be in tunnel, out of range, or network is down');
      await _log('   Keeping VPN connected - will resume when network returns');
      _consecutiveFailures = 0; // Reset counter
      return;
    }

    // ✅ We have network adapters but VPN pings fail
    // This means VPN itself is broken (expired credentials, server down, etc)
    await _log('🔴 VPN IS BROKEN!');
    await _log('   ✅ Device has active network adapters');
    await _log('   ❌ VPN pings are failing');
    await _log('   → VPN credentials likely expired or connection broken');

    final reason = 'vpn_broken';
    final message = 'VPN is connected but internet is not accessible. Your credentials may have expired or the connection is broken. VPN has been disconnected.';

    // ✅ Actually STOP the VPN!
    await _log('🛑 STOPPING BROKEN VPN...');

    // Send death event FIRST
    _eventController.add(VpnEvent(
      type: VpnEventType.died,
      reason: reason,
      message: message,
    ));

    // ✅ Inline stop logic (can't call instance method from static)
    _isNormalStop = true; // Mark as normal to prevent duplicate death event
    _stopProcessChecker();
    _stopHeartbeatMonitoring();

    // Notify backend
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();
      if (deviceId != null && apiKey != null) {
        await http.post(
          Uri.parse('https://api.vulcainvpn.com/api/disconnect/$deviceId'),
          headers: {'X-Api-Key': apiKey},
        );
      }
    } catch (e) {
      await _log('Failed to notify backend: $e');
    }

    // Kill process
    _singBoxProcess?.kill();
    _singBoxProcess = null;

    // Clean up config files
    try {
      if (_plaintextPath != null && await File(_plaintextPath!).exists()) {
        await SecureConfigService.secureDelete(_plaintextPath!);
      }
      if (_configPath != null && await File(_configPath!).exists()) {
        await SecureConfigService.secureDelete(_configPath!);
      }
      _plaintextPath = null;
      _configPath = null;
    } catch (e) {
      await _log('Config cleanup error: $e');
    }

    // Kill by name
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
    } catch (e) {
      await _log('taskkill error: $e');
    }

    _isConnected = false;
    _statusController.add(false);

    // Reset counter
    _consecutiveFailures = 0;

    await _log('✅ VPN stopped due to broken connection');
  }

  // ✅ PRIORITY 2: Check basic network connectivity
  static Future<bool> _checkBasicConnectivity() async {
    try {
      // Try to ping Google DNS
      final result = await Process.run(
        'ping',
        ['-n', '1', '-w', '3000', '8.8.8.8'],
      );

      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  // ✅ PRIORITY 2: Check if device has any active network
  static Future<bool> _checkForAnyNetwork() async {
    try {
      // Check for active network adapters (excluding VPN)
      final result = await Process.run(
        'netsh',
        ['interface', 'show', 'interface'],
      );

      final output = result.stdout.toString();

      // Look for "Connected" status on WiFi, Ethernet, or Cellular interfaces
      // Exclude VPN adapters (usually named "sing-box" or similar)
      final lines = output.split('\n');

      for (final line in lines) {
        if (line.contains('Connected') &&
            !line.toLowerCase().contains('vpn') &&
            !line.toLowerCase().contains('sing-box') &&
            !line.toLowerCase().contains('wintun')) {
          // Found active non-VPN network adapter
          await _log('   Found active network: ${line.trim()}');
          return true;
        }
      }

      await _log('   No active non-VPN network adapters found');
      return false;
    } catch (e) {
      await _log('   Error checking network adapters: $e');
      // On error, assume we have network (safer to stop VPN than leave broken)
      return true;
    }
  }

  @override
  Future<bool> startVpn() async {
    try {
      await _log('startVpn called');

      // ✅ Reset normal stop flag
      _isNormalStop = false;

      // ✅ PRIORITY 2: Reset heartbeat counters
      _consecutiveFailures = 0;
      _lastSuccessfulPing = DateTime.now();

      // Step 1: Get device credentials
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('Error: Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      await _log('Fetching credentials for device: $deviceId');

      // Step 2: Call /api/connect to get credentials
      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      // ✅ NEW: Handle different status codes
      if (response.statusCode == 401) {
        await _log('Unauthorized (401)');
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Device not registered. Please login again.');
      }

      if (response.statusCode == 403) {
        await _log('Forbidden - No active subscription (403)');
        final errorData = json.decode(response.body);
        throw Exception(
          '${errorData['error'] ?? 'No active subscription'}|'
          'renewal_url:${errorData['renewal_url'] ?? 'https://www.vulcainvpn.com/dashboard'}'
        );
      }

      if (response.statusCode == 429) {
        await _log('Too Many Requests - Device limit (429)');
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ?? 'Maximum active devices reached');
      }

      if (response.statusCode != 200) {
        await _log('Failed to get credentials: ${response.statusCode}');
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
        await _log('No credentials available');
        throw Exception('Failed to get connection credentials');
      }

      await _log('Credentials received');

      // Step 3: Build dynamic config
      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      // Step 4: Convert to JSON string
      final configJson = VpnConfigService.toJsonString(config);
      await _log('Config built successfully');

      // Step 5: Write encrypted config to temp file
      await _log('exe dir: $_exeDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      final tempDir = await getTemporaryDirectory();
      _configPath = '${tempDir.path}\\config.json.enc';
      _plaintextPath = '${tempDir.path}\\config.json';

      await SecureConfigService.writeEncryptedConfig(_configPath!, configJson);
      await _log('encrypted config written to: $_configPath');

      // For sing-box, write plaintext temporarily
      await File(_plaintextPath!).writeAsString(configJson);

      // Step 6: Start sing-box process
      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', _plaintextPath!],
      );
      await _log('process started with pid: ${_singBoxProcess!.pid}');

      _singBoxProcess!.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box: $data'));
      _singBoxProcess!.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box ERR: $data'));

      _singBoxProcess!.exitCode.then((code) async {
        _log('sing-box exited with code: $code');

        // Clean up config files on exit
        if (_plaintextPath != null) {
          await SecureConfigService.secureDelete(_plaintextPath!);
        }
        if (_configPath != null) {
          await SecureConfigService.secureDelete(_configPath!);
        }

        _plaintextPath = null;
        _configPath = null;

        if (_isConnected) {
          _isConnected = false;
          _statusController.add(false);

          // ✅ PRIORITY 1: Only send death event if NOT a normal stop and exit code != 0
          if (!_isNormalStop && code != 0) {
            _eventController.add(VpnEvent(
              type: VpnEventType.died,
              reason: 'process_exited',
              message: 'sing-box exited with code $code',
            ));
          }
        }
      });

      await Future.delayed(const Duration(seconds: 2));
      _isConnected = true;
      _statusController.add(true);

      // ✅ PRIORITY 1: Start process checker
      _startProcessChecker();

      // ✅ PRIORITY 2: Start heartbeat monitoring
      _startHeartbeatMonitoring();

      // ✅ PRIORITY 1: Send connected event
      _eventController.add(VpnEvent(
        type: VpnEventType.connected,
        message: 'VPN connected successfully',
      ));

      return true;
    } catch (e) {
      await _log('Windows VPN error: $e');
      rethrow;  // ✅ CHANGED: Rethrow instead of returning false
    }
  }

  @override
  Future<void> stopVpn() async {
    await _log('stopVpn called');

    // ✅ Set flag BEFORE stopping (prevents false "died" event)
    _isNormalStop = true;

    // ✅ PRIORITY 1: Stop process checker
    _stopProcessChecker();

    // ✅ PRIORITY 2: Stop heartbeat monitoring
    _stopHeartbeatMonitoring();

    // Notify backend of disconnection
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId != null && apiKey != null) {
        await http.post(
          Uri.parse('https://api.vulcainvpn.com/api/disconnect/$deviceId'),
          headers: {'X-Api-Key': apiKey},
        );
        await _log('Backend notified of disconnection');
      }
    } catch (e) {
      await _log('Failed to notify backend: $e');
    }

    // Kill process
    _singBoxProcess?.kill();
    _singBoxProcess = null;

    // Clean up config files
    try {
      if (_plaintextPath != null && await File(_plaintextPath!).exists()) {
        await SecureConfigService.secureDelete(_plaintextPath!);
        await _log('Plaintext config deleted');
      }
      if (_configPath != null && await File(_configPath!).exists()) {
        await SecureConfigService.secureDelete(_configPath!);
        await _log('Encrypted config deleted');
      }
      _plaintextPath = null;
      _configPath = null;
    } catch (e) {
      await _log('Config cleanup error: $e');
    }

    // Kill by name in case process was started in a previous session
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
    } catch (e) {
      await _log('taskkill error: $e');
    }

    _isConnected = false;
    _statusController.add(false);

    // ✅ PRIORITY 1: Send disconnected event
    _eventController.add(VpnEvent(
      type: VpnEventType.disconnected,
      message: 'VPN disconnected by user',
    ));
  }

  @override
  Future<bool> checkNotificationPermission() async => true;
}
