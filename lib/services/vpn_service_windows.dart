import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';
import 'vpn_service_android.dart'; // For VpnEvent types
import 'windows_notification_service.dart';

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;
  static bool _isNormalStop = false;

  // Path of the sing-box config file for the current session.
  // 🔐 Stored in the app's private support folder (per-user), not in %TEMP%.
  // The old code also wrote an "encrypted" copy next to it that nothing ever
  // read (sing-box needs the plaintext), using AES-GCM with a fixed IV, which
  // is unsafe. That copy and secure_config_service.dart are removed.
  static String? _plaintextPath;

  // ✅ PRIORITY 1: Process checker timer
  static Timer? _processChecker;
  static final StreamController<VpnEvent> _eventController = StreamController<VpnEvent>.broadcast();

  // ✅ PRIORITY 2: Heartbeat monitoring
  static Timer? _heartbeatTimer;
  static int _consecutiveFailures = 0;
  static DateTime? _lastSuccessfulPing;
  static const int _heartbeatIntervalSeconds = 10;
  static const int _maxConsecutiveFailures = 3;
  static const String _pingHost = 'api.vulcainvpn.com';

  // ✅ NEW: Network recovery tracking
  static bool _wasNetworkLost = false;
  static DateTime? _networkLostTimestamp;

  // ✅ NEW: Race condition fix - 4 minutes threshold
  static const int maxAutoReconnectDurationSeconds = 240;

  // ✅ NEW: 403 error tracking for subscription expiry detection
  static int _auth403Count = 0;
  static Timer? _auth403Timer;
  static bool _isHandlingSubscriptionExpiry = false;

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;
  static String get _logPath => '$_exeDir\\vpn_log.txt';


  // 🔐 Delete the session's sing-box config file (contains VPN credentials).
  // A plain delete is enough: multi-pass overwrites do nothing useful on SSDs
  // (wear levelling writes to new blocks), and the credentials are rotated
  // server-side after the device disconnects anyway.
  static Future<void> _deleteConfigFile() async {
    final path = _plaintextPath;
    _plaintextPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      await _log('Config delete error: $e');
    }
  }

  // Remove config files left in %TEMP% by versions up to 1.0.23
  static bool _legacyCleanupDone = false;
  static Future<void> _cleanupLegacyTempConfigs() async {
    if (_legacyCleanupDone) return;
    _legacyCleanupDone = true;
    try {
      final tempDir = await getTemporaryDirectory();
      for (final name in ['config.json', 'config.json.enc']) {
        final f = File('${tempDir.path}\\$name');
        if (await f.exists()) {
          await f.delete();
        }
      }
    } catch (_) {
      // Best effort only
    }
  }

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

  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream => _statusController.stream;

  // ✅ NEW: Reset 403 counter periodically
  static void _reset403Counter() {
    _auth403Timer?.cancel();
    _auth403Timer = Timer(Duration(seconds: 30), () {
      _auth403Count = 0;
    });
  }

  // ✅ NEW: Handle subscription expiry detected from 403 errors
  static Future<void> _handleSubscriptionExpired() async {
    // ✅ CRITICAL: Prevent multiple simultaneous calls (race condition fix)
    if (_isHandlingSubscriptionExpiry) {
      await _log('⚠️ Already handling subscription expiry, ignoring duplicate call');
      return;
    }

    _isHandlingSubscriptionExpiry = true;

    await _log('🔴 STOPPING VPN - Subscription expired');

    // Prevent duplicate death events
    if (!_isConnected) {
      await _log('⚠️ Already disconnected, ignoring');
      _isHandlingSubscriptionExpiry = false;
      return;
    }

    // Mark as normal stop to prevent process death event
    _isNormalStop = true;

    // Stop monitoring
    _stopProcessChecker();
    _stopHeartbeatMonitoring();

    // Reset counters
    _auth403Count = 0;
    _auth403Timer?.cancel();

    // ✅ NEW: Show critical notification (toast + window focus)
    await WindowsNotificationService.showCriticalAlert(
      title: 'VPN Disconnected',
      message: 'Your subscription has expired. Please renew to continue.',
    );

    // Send death event FIRST (before stopping process)
    _eventController.add(VpnEvent(
      type: VpnEventType.died,
      reason: 'subscription_expired',
      message: 'Your VPN subscription has expired',
    ));

    // ✅ FIXED: Force kill process FIRST
    await _log('🔪 Force killing sing-box process...');
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
      await _log('   taskkill completed');
    } catch (e) {
      await _log('   taskkill error: $e');
    }

    // Wait for process to fully terminate
    await Future.delayed(Duration(milliseconds: 500));

    _singBoxProcess?.kill();
    _singBoxProcess = null;

    // Clean up configs (should work now that process is dead)
    try {
      await _deleteConfigFile();
      await _log('   Config file deleted');
    } catch (e) {
      await _log('Config cleanup error: $e');
    }

    // Update state
    _isConnected = false;
    _statusController.add(false);

    await _log('✅ VPN stopped due to subscription expiry');

    // ✅ Reset guard at the very end
    _isHandlingSubscriptionExpiry = false;
  }

  static void _startProcessChecker() {
    _processChecker?.cancel();

    _processChecker = Timer.periodic(Duration(seconds: 3), (timer) async {
      if (!_isConnected) {
        timer.cancel();
        return;
      }

      final isRunning = await _isSingBoxRunning();

      if (!isRunning && _isConnected) {
        if (!_isNormalStop) {
          await _log('⚠️ sing-box process died unexpectedly!');

          _isConnected = false;
          _statusController.add(false);

          // ✅ NEW: Show critical notification (toast + window focus)
          await WindowsNotificationService.showCriticalAlert(
            title: 'VPN Crashed',
            message: 'VPN process stopped unexpectedly. Please restart.',
          );

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

  static void _stopProcessChecker() {
    _processChecker?.cancel();
    _processChecker = null;
  }

  static Future<bool> _isSingBoxRunning() async {
    try {
      final result1 = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq sing-box-amd64.exe', '/NH'],
      );

      if (result1.stdout.toString().contains('sing-box-amd64.exe')) {
        return true;
      }

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

  static void _startHeartbeatMonitoring() {
    _stopHeartbeatMonitoring();

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
            if (_consecutiveFailures > 0) {
              await _log('💚 Heartbeat recovered after $_consecutiveFailures failures');
            }
            _consecutiveFailures = 0;
            _lastSuccessfulPing = DateTime.now();
          } else {
            _consecutiveFailures++;
            final timeSinceLastSuccess = DateTime.now().difference(_lastSuccessfulPing!).inSeconds;

            await _log('💔 Heartbeat failed ($_consecutiveFailures/$_maxConsecutiveFailures) - Last success: ${timeSinceLastSuccess}s ago');

            if (_consecutiveFailures >= _maxConsecutiveFailures) {
              await _handleHeartbeatFailure();
            }
          }
        } catch (e) {
          await _log('Heartbeat check error: $e');
        }
      },
    );
  }

  static void _stopHeartbeatMonitoring() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _consecutiveFailures = 0;
    _log('💓 Stopped heartbeat monitoring');
  }

  static Future<bool> _performHeartbeatCheck() async {
    try {
      final result = await Process.run(
        'ping',
        ['-n', '1', '-w', '3000', _pingHost],
      );

      final success = result.exitCode == 0;

      if (success) {
        await _log('💚 Ping OK: $_pingHost');

        if (_wasNetworkLost) {
          final downtime = DateTime.now().difference(_networkLostTimestamp!).inSeconds;
          await _log('🔄 NETWORK RECOVERED after ${downtime}s!');
          await _log('   Attempting to restart VPN tunnel...');

          await _handleNetworkRecovery();

          _wasNetworkLost = false;
        }
      } else {
        await _log('💔 Ping FAILED: $_pingHost');
      }

      return success;
    } catch (e) {
      await _log('💔 Ping exception: $e');
      return false;
    }
  }

  static Future<void> _handleHeartbeatFailure() async {
    await _log('🚨 HEARTBEAT FAILURE DETECTED!');
    await _log('   VPN is connected but no internet access through VPN');
    await _log('   3 consecutive ping failures detected');

    final hasAnyNetwork = await _checkForAnyNetwork();

    if (!hasAnyNetwork) {
      await _log('📶 NO NETWORK DETECTED');
      await _log('   User may be in tunnel, airplane mode, or network is down');
      await _log('   Keeping VPN connected - will resume when network returns');

      if (!_wasNetworkLost) {
        _wasNetworkLost = true;
        _networkLostTimestamp = DateTime.now();
        await _log('   📍 Marking network as lost at ${_networkLostTimestamp}');

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('last_seen_at', _networkLostTimestamp!.millisecondsSinceEpoch);

        // ✅ NEW: Show toast notification (non-critical)
        await WindowsNotificationService.showToast(
          title: 'Network Lost',
          message: 'VPN will reconnect when network returns',
        );

        await _log('   📡 Sending network_lost event to Flutter');
        _eventController.add(VpnEvent(
          type: VpnEventType.died,
          reason: 'network_lost',
          message: 'Network connection lost. VPN will reconnect automatically when network returns.',
        ));
      }

      _consecutiveFailures = 0;
      return;
    }

    await _log('🔴 VPN IS BROKEN!');
    await _log('   ✅ Device has active network adapters');
    await _log('   ❌ VPN pings are failing');
    await _log('   → VPN credentials likely expired or connection broken');

    final reason = 'vpn_broken';
    final message = 'VPN connection lost. Please reconnect.';

    _wasNetworkLost = false;

    await _log('🛑 STOPPING BROKEN VPN...');

    // ✅ NEW: Show toast notification (important but not critical)
    await WindowsNotificationService.showToast(
      title: 'VPN Connection Lost',
      message: 'Please reconnect to restore protection',
      isError: true,
    );

    _eventController.add(VpnEvent(
      type: VpnEventType.died,
      reason: reason,
      message: message,
    ));

    _isNormalStop = true;
    _stopProcessChecker();
    _stopHeartbeatMonitoring();

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

    // ✅ FIXED: Force kill FIRST, then cleanup
    await _log('🔪 Force killing sing-box process...');
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
    } catch (e) {
      await _log('taskkill error: $e');
    }

    await Future.delayed(Duration(milliseconds: 500));

    _singBoxProcess?.kill();
    _singBoxProcess = null;

    try {
      await _deleteConfigFile();
    } catch (e) {
      await _log('Config cleanup error: $e');
    }

    _isConnected = false;
    _statusController.add(false);

    _consecutiveFailures = 0;

    await _log('✅ VPN stopped due to broken connection');
  }

  static Future<void> _handleNetworkRecovery() async {
    try {
      await _log('🔄 Network recovered - checking disconnection duration...');

      final prefs = await SharedPreferences.getInstance();
      final lastSeenAt = prefs.getInt('last_seen_at') ?? DateTime.now().millisecondsSinceEpoch;
      final now = DateTime.now().millisecondsSinceEpoch;
      final disconnectedSeconds = (now - lastSeenAt) ~/ 1000;

      await _log('   ⏱️ Disconnected for ${disconnectedSeconds}s (threshold: ${maxAutoReconnectDurationSeconds}s)');

      if (disconnectedSeconds < maxAutoReconnectDurationSeconds) {
        await _log('   ✅ Short disconnection - restarting VPN with cached config');
        await _restartVpnWithCachedConfig();
      } else {
        final minutes = disconnectedSeconds ~/ 60;
        await _log('   ⚠️ Long disconnection (${minutes} min) - sending death event for manual reconnect');

        _isNormalStop = true;

        // ✅ FIXED: Force kill first
        try {
          await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
          await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
        } catch (e) {
          await _log('taskkill error: $e');
        }

        await Future.delayed(Duration(milliseconds: 500));

        _singBoxProcess?.kill();
        _singBoxProcess = null;

        _isConnected = false;
        _statusController.add(false);

        // ✅ NEW: Show toast for long disconnection
        await WindowsNotificationService.showToast(
          title: 'VPN Disconnected',
          message: minutes > 0
              ? 'You were offline for $minutes minute${minutes > 1 ? 's' : ''}. Tap to reconnect.'
              : 'Network recovered. Tap to reconnect.',
          isError: true,
        );

        _eventController.add(VpnEvent(
          type: VpnEventType.died,
          reason: 'vpn_broken',
          message: minutes > 0
              ? 'You were offline for $minutes minute${minutes > 1 ? 's' : ''}. Tap to reconnect.'
              : 'Network recovered. Tap to reconnect with fresh credentials.',
        ));
      }

    } catch (e) {
      await _log('❌ Failed to handle network recovery: $e');
    }
  }

  static Future<void> _restartVpnWithCachedConfig() async {
    try {
      await _log('   Starting VPN recovery process with cached config...');

      await _log('   Step 1: Stopping current VPN instance...');
      _isNormalStop = true;

      // ✅ FIXED: Force kill first
      try {
        await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
        await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
      } catch (e) {
        await _log('taskkill error: $e');
      }

      _singBoxProcess?.kill();
      _singBoxProcess = null;

      await _log('   Step 2: Waiting for cleanup...');
      await Future.delayed(Duration(seconds: 1));

      await _log('   Step 3: Checking config availability...');
      if (_plaintextPath == null || !await File(_plaintextPath!).exists()) {
        throw Exception('No config available for recovery');
      }

      await _log('   Step 4: Restarting sing-box process...');
      _isNormalStop = false;
      _consecutiveFailures = 0;
      _lastSuccessfulPing = DateTime.now();

      final singBoxExe = File(_singBoxPath);
      if (!await singBoxExe.exists()) {
        throw Exception('sing-box executable not found at $_singBoxPath');
      }

      await _log('   Starting sing-box process for recovery...');
      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', _plaintextPath!],
        workingDirectory: _exeDir,
      );

      _singBoxProcess!.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box: $data'));

      // ✅ Monitor stderr for 403 errors during recovery too
      _singBoxProcess!.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) async {
            await _log('sing-box ERR: $data');

            if (data.contains('authentication failed, status code: 403')) {
              _auth403Count++;
              _reset403Counter();

              if (_auth403Count >= 5) {
                await _log('🚨 SUBSCRIPTION EXPIRED DETECTED during recovery');
                await _handleSubscriptionExpired();
              }
            }
          });

      await _log('   Step 5: Verifying VPN started...');
      await Future.delayed(Duration(seconds: 3));

      final isRunning = await _isSingBoxRunning();
      if (!isRunning) {
        throw Exception('sing-box process not running after recovery');
      }

      _isConnected = true;
      _statusController.add(true);

      await _log('✅ VPN successfully restarted after network recovery');

      // ✅ NEW: Show success notification
      await WindowsNotificationService.showToast(
        title: 'VPN Reconnected',
        message: 'Your VPN connection has been restored',
      );

      _eventController.add(VpnEvent(
        type: VpnEventType.connected,
        message: 'VPN reconnected after network recovery',
      ));

      _startProcessChecker();
      _startHeartbeatMonitoring();

    } catch (e) {
      await _log('❌ Failed to restart VPN after network recovery: $e');

      _isNormalStop = false;
      _wasNetworkLost = false;

      // ✅ NEW: Show failure notification
      await WindowsNotificationService.showToast(
        title: 'VPN Recovery Failed',
        message: 'Failed to reconnect. Please connect manually.',
        isError: true,
      );

      _eventController.add(VpnEvent(
        type: VpnEventType.died,
        reason: 'vpn_broken',
        message: 'Failed to recover VPN after network change: $e',
      ));

      _isConnected = false;
      _statusController.add(false);
    }
  }

  static Future<bool> _checkForAnyNetwork() async {
    try {
      final result = await Process.run(
        'netsh',
        ['interface', 'show', 'interface'],
      );

      final output = result.stdout.toString();
      final lines = output.split('\n');

      for (final line in lines) {
        if (line.contains('Connected') &&
            !line.toLowerCase().contains('vpn') &&
            !line.toLowerCase().contains('sing-box') &&
            !line.toLowerCase().contains('wintun')) {
          await _log('   Found active network: ${line.trim()}');
          return true;
        }
      }

      await _log('   No active non-VPN network adapters found');
      return false;
    } catch (e) {
      await _log('   Error checking network adapters: $e');
      return true;
    }
  }

  @override
  Future<bool> startVpn() async {
    try {
      await _log('startVpn called');

      _isNormalStop = false;
      _consecutiveFailures = 0;
      _lastSuccessfulPing = DateTime.now();
      _wasNetworkLost = false;

      // ✅ NEW: Reset 403 counter and guard flag
      _auth403Count = 0;
      _auth403Timer?.cancel();
      _isHandlingSubscriptionExpiry = false;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_seen_at', DateTime.now().millisecondsSinceEpoch);

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('Error: Device not registered');
        throw Exception('Device not registered. Please login again.');
      }

      // Log file exists in release builds too: only a short prefix of the ID
      await _log('Fetching credentials for device: ${deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId}...');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

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

      if (response.statusCode == 503) {
        await _log('Service Unavailable - Technical issue (503)');
        final errorData = json.decode(response.body);
        throw Exception('TECHNICAL_ISSUE|${errorData['message'] ?? 'We\'re experiencing technical difficulties. Please try again shortly.'}');
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

      final config = await VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      await _log('Config built successfully');

      await _log('exe dir: $_exeDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      // 🔐 Per-user app folder (%APPDATA%\<company>\<app>) instead of %TEMP%.
      // Leftovers from older versions are removed once.
      await _cleanupLegacyTempConfigs();
      final supportDir = await getApplicationSupportDirectory();
      await supportDir.create(recursive: true);
      _plaintextPath = '${supportDir.path}\\config.json';

      await File(_plaintextPath!).writeAsString(configJson, flush: true);
      await _log('config written to app support folder');

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', _plaintextPath!],
      );
      await _log('process started with pid: ${_singBoxProcess!.pid}');

      _singBoxProcess!.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box: $data'));

      // ✅ CRITICAL FIX: Monitor stderr for 403 errors
      _singBoxProcess!.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) async {
            await _log('sing-box ERR: $data');

            // ✅ NEW: Detect subscription expiry from 403 errors
            if (data.contains('authentication failed, status code: 403')) {
              _auth403Count++;
              _reset403Counter();

              // If we see 5+ auth failures in 30 seconds, subscription likely expired
              if (_auth403Count >= 5) {
                await _log('🚨 SUBSCRIPTION EXPIRED DETECTED (403 errors from sing-box)');
                await _log('   Detected $_auth403Count authentication failures');

                // Stop VPN immediately
                await _handleSubscriptionExpired();
              }
            }
          });

      _singBoxProcess!.exitCode.then((code) async {
        _log('sing-box exited with code: $code');

        await _deleteConfigFile();

        if (_isConnected) {
          _isConnected = false;
          _statusController.add(false);

          if (!_isNormalStop && code != 0) {
            // ✅ NEW: Show notification for abnormal exit
            await WindowsNotificationService.showToast(
              title: 'VPN Process Exited',
              message: 'VPN stopped with exit code $code',
              isError: true,
            );

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

      _startProcessChecker();
      _startHeartbeatMonitoring();

      _eventController.add(VpnEvent(
        type: VpnEventType.connected,
        message: 'VPN connected successfully',
      ));

      return true;
    } catch (e) {
      await _log('Windows VPN error: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopVpn() async {
    await _log('stopVpn called');

    _isNormalStop = true;

    // ✅ NEW: Reset 403 counter and guard flag
    _auth403Count = 0;
    _auth403Timer?.cancel();
    _isHandlingSubscriptionExpiry = false;

    _stopProcessChecker();
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

    // ✅ CRITICAL FIX: Force kill FIRST, THEN cleanup configs
    await _log('🔪 Force killing sing-box process...');
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
      await _log('   taskkill completed');
    } catch (e) {
      await _log('   taskkill error: $e');
    }

    // Wait for process to fully terminate
    await Future.delayed(Duration(milliseconds: 500));

    _singBoxProcess?.kill();
    _singBoxProcess = null;

    // Clean up config files (should work now that process is dead)
    try {
      await _deleteConfigFile();
      await _log('Config file deleted');
    } catch (e) {
      await _log('Config cleanup error: $e');
    }

    _isConnected = false;
    _statusController.add(false);

    _eventController.add(VpnEvent(
      type: VpnEventType.disconnected,
      message: 'VPN disconnected by user',
    ));
  }

  @override
  Future<bool> checkNotificationPermission() async => true;

  @override
  Future<VpnEvent?> checkForDeathEvents() async {
    return null;
  }

  @override
  Future<String> checkSubscription() async {
    try {
      await _log('🔍 Checking subscription status...');

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('❌ No credentials found');
        return 'unknown';
      }

      final response = await http.get(
        Uri.parse('https://api.vulcainvpn.com/api/subscription'),
        headers: {'X-Api-Key': apiKey},
      );

      await _log('📡 HTTP Response: ${response.statusCode}');

      if (response.statusCode == 200) {
        try {
          final json = jsonDecode(response.body);
          final sub = json['subscription'];
          final status = sub['status'] as String;

          await _log('✅ Subscription status: $status');

          return status != 'active' ? 'expired' : 'active';
        } catch (e) {
          await _log('❌ JSON parse error: $e');
          return 'unknown';
        }
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        await _log('❌ Subscription expired (HTTP ${response.statusCode})');
        return 'expired';
      } else {
        await _log('⚠️ Unexpected status code: ${response.statusCode}');
        return 'unknown';
      }
    } catch (e) {
      await _log('❌ Subscription check error: $e');
      return 'unknown';
    }
  }

  @override
  Future<void> reconnectVpn() async {
    try {
      await _log('🔄 Attempting to reconnect...');

      await _log('🔍 Checking subscription before reconnect...');
      final subscriptionStatus = await checkSubscription();

      if (subscriptionStatus == 'expired') {
        await _log('❌ Subscription expired - blocking reconnect');
        throw Exception('subscription_expired');
      }

      if (subscriptionStatus == 'active') {
        await _log('✅ Subscription active - proceeding with reconnect');
      } else {
        await _log('⚠️ Could not verify subscription - allowing reconnect attempt');
      }

      await startVpn();

    } catch (e) {
      await _log('❌ Reconnect failed: $e');
      rethrow;
    }
  }
}
