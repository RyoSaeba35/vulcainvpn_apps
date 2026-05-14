import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';
import 'vpn_service_android.dart'; // For VpnEvent types
import 'macos_notification_service.dart';

class MacosVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;
  static bool _isNormalStop = false;

  static String? _plaintextPath;

  static Timer? _processChecker;
  static final StreamController<VpnEvent> _eventController =
      StreamController<VpnEvent>.broadcast();

  // Heartbeat monitoring
  static Timer? _heartbeatTimer;
  static int _consecutiveFailures = 0;
  static DateTime? _lastSuccessfulPing;
  static const int _heartbeatIntervalSeconds = 10;
  static const int _maxConsecutiveFailures = 3;
  static const String _pingHost = 'api.vulcainvpn.com';

  static bool _wasNetworkLost = false;
  static DateTime? _networkLostTimestamp;
  static const int maxAutoReconnectDurationSeconds = 240;

  // 403 subscription expiry tracking
  static int _auth403Count = 0;
  static Timer? _auth403Timer;
  static bool _isHandlingSubscriptionExpiry = false;

  /// Path to the app bundle's Resources folder (where sing-box binary lives)
  static String get _resourcesDir {
    return '${File(Platform.resolvedExecutable).parent.parent.path}/Resources';
  }

  static String get _logPath => '$_resourcesDir/vpn_log.txt';

  static Future<void> _log(String message) async {
    try {
      final logFile = File(_logPath);
      if (await logFile.exists()) {
        final size = await logFile.length();
        if (size > 1024 * 1024) {
          await logFile.rename('$_resourcesDir/vpn_log_old.txt');
        }
      }
      final timestamp = DateTime.now().toIso8601String();
      await logFile.writeAsString('$timestamp: $message\n',
          mode: FileMode.append);
    } catch (e) {
      print('Log error: $e');
    }
    print(message);
  }

  /// Safe file delete — plain File.delete, no keychain/security APIs
  static Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      await _log('File delete error ($path): $e');
    }
  }

  /// Detect architecture and return the correct sing-box binary name
  static String get _singBoxPath {
    final result = Process.runSync('uname', ['-m']);
    final arch = result.stdout.toString().trim();
    final binary = arch.contains('arm') ? 'sing-box-arm64' : 'sing-box-amd64';
    return '$_resourcesDir/$binary';
  }

  static Stream<VpnEvent> get eventStream => _eventController.stream;

  @override
  Stream<bool> get statusStream => _statusController.stream;

  static void _reset403Counter() {
    _auth403Timer?.cancel();
    _auth403Timer = Timer(const Duration(seconds: 30), () {
      _auth403Count = 0;
    });
  }

  static Future<void> _handleSubscriptionExpired() async {
    if (_isHandlingSubscriptionExpiry) {
      await _log('Already handling subscription expiry, ignoring duplicate');
      return;
    }
    _isHandlingSubscriptionExpiry = true;

    await _log('STOPPING VPN - Subscription expired');

    if (!_isConnected) {
      await _log('Already disconnected, ignoring');
      _isHandlingSubscriptionExpiry = false;
      return;
    }

    _isNormalStop = true;
    _stopProcessChecker();
    _stopHeartbeatMonitoring();
    _auth403Count = 0;
    _auth403Timer?.cancel();

    await MacosNotificationService.showCriticalAlert(
      title: 'VPN Disconnected',
      message: 'Your subscription has expired. Please renew to continue.',
    );

    _eventController.add(VpnEvent(
      type: VpnEventType.died,
      reason: 'subscription_expired',
      message: 'Your VPN subscription has expired',
    ));

    await _killSingBox();
    await _deleteFile(_plaintextPath);
    _plaintextPath = null;

    _isConnected = false;
    _statusController.add(false);
    _isHandlingSubscriptionExpiry = false;
  }

  /// Kill sing-box using pkill (macOS equivalent of taskkill)
  static Future<void> _killSingBox() async {
    try {
      await Process.run('pkill', ['-9', '-f', 'sing-box']);
      await _log('pkill completed');
    } catch (e) {
      await _log('pkill error: $e');
    }
    await Future.delayed(const Duration(milliseconds: 500));
    _singBoxProcess?.kill(ProcessSignal.sigkill);
    _singBoxProcess = null;
  }

  static void _startProcessChecker() {
    _processChecker?.cancel();
    _processChecker =
        Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_isConnected) {
        timer.cancel();
        return;
      }

      final isRunning = await _isSingBoxRunning();

      if (!isRunning && _isConnected) {
        if (!_isNormalStop) {
          await _log('sing-box process died unexpectedly!');
          _isConnected = false;
          _statusController.add(false);

          await MacosNotificationService.showCriticalAlert(
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

  /// Check if sing-box is running using pgrep (macOS equivalent of tasklist)
  static Future<bool> _isSingBoxRunning() async {
    try {
      final result = await Process.run('pgrep', ['-f', 'sing-box']);
      return result.exitCode == 0;
    } catch (e) {
      await _log('Error checking process: $e');
      return false;
    }
  }

  static void _startHeartbeatMonitoring() {
    _stopHeartbeatMonitoring();
    _log('Starting heartbeat monitoring (every ${_heartbeatIntervalSeconds}s)');
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
              await _log(
                  'Heartbeat recovered after $_consecutiveFailures failures');
            }
            _consecutiveFailures = 0;
            _lastSuccessfulPing = DateTime.now();
          } else {
            _consecutiveFailures++;
            final timeSinceLastSuccess =
                DateTime.now().difference(_lastSuccessfulPing!).inSeconds;
            await _log(
                'Heartbeat failed ($_consecutiveFailures/$_maxConsecutiveFailures) '
                '- Last success: ${timeSinceLastSuccess}s ago');

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
  }

  /// macOS ping: ping -c 1 -W 3 host (timeout in seconds, not ms)
  static Future<bool> _performHeartbeatCheck() async {
    try {
      final result = await Process.run(
        'ping',
        ['-c', '1', '-W', '3', _pingHost],
      );

      final success = result.exitCode == 0;

      if (success) {
        await _log('Ping OK: $_pingHost');
        if (_wasNetworkLost) {
          final downtime =
              DateTime.now().difference(_networkLostTimestamp!).inSeconds;
          await _log('NETWORK RECOVERED after ${downtime}s!');
          await _handleNetworkRecovery();
          _wasNetworkLost = false;
        }
      } else {
        await _log('Ping FAILED: $_pingHost');
      }

      return success;
    } catch (e) {
      await _log('Ping exception: $e');
      return false;
    }
  }

  static Future<void> _handleHeartbeatFailure() async {
    await _log('HEARTBEAT FAILURE DETECTED!');
    final hasAnyNetwork = await _checkForAnyNetwork();

    if (!hasAnyNetwork) {
      await _log('NO NETWORK DETECTED - Keeping VPN, will resume when back');

      if (!_wasNetworkLost) {
        _wasNetworkLost = true;
        _networkLostTimestamp = DateTime.now();

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
            'last_seen_at', _networkLostTimestamp!.millisecondsSinceEpoch);

        await MacosNotificationService.showToast(
          title: 'Network Lost',
          message: 'VPN will reconnect when network returns',
        );

        _eventController.add(VpnEvent(
          type: VpnEventType.died,
          reason: 'network_lost',
          message:
              'Network connection lost. VPN will reconnect automatically when network returns.',
        ));
      }

      _consecutiveFailures = 0;
      return;
    }

    await _log('VPN IS BROKEN - Device has network but VPN pings failing');
    _wasNetworkLost = false;

    await MacosNotificationService.showToast(
      title: 'VPN Connection Lost',
      message: 'Please reconnect to restore protection',
      isError: true,
    );

    _eventController.add(VpnEvent(
      type: VpnEventType.died,
      reason: 'vpn_broken',
      message: 'VPN connection lost. Please reconnect.',
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

    await _killSingBox();
    await _deleteFile(_plaintextPath);
    _plaintextPath = null;

    _isConnected = false;
    _statusController.add(false);
    _consecutiveFailures = 0;
  }

  static Future<void> _handleNetworkRecovery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSeenAt =
          prefs.getInt('last_seen_at') ?? DateTime.now().millisecondsSinceEpoch;
      final now = DateTime.now().millisecondsSinceEpoch;
      final disconnectedSeconds = (now - lastSeenAt) ~/ 1000;

      await _log(
          'Disconnected for ${disconnectedSeconds}s (threshold: ${maxAutoReconnectDurationSeconds}s)');

      if (disconnectedSeconds < maxAutoReconnectDurationSeconds) {
        await _log('Short disconnection - restarting VPN with cached config');
        await _restartVpnWithCachedConfig();
      } else {
        final minutes = disconnectedSeconds ~/ 60;
        await _log('Long disconnection (${minutes} min) - sending death event');

        _isNormalStop = true;
        await _killSingBox();
        await _deleteFile(_plaintextPath);
        _plaintextPath = null;

        _isConnected = false;
        _statusController.add(false);

        await MacosNotificationService.showToast(
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
              : 'Network recovered. Tap to reconnect.',
        ));
      }
    } catch (e) {
      await _log('Failed to handle network recovery: $e');
    }
  }

  static Future<void> _restartVpnWithCachedConfig() async {
    try {
      await _log('Restarting VPN with cached config...');
      _isNormalStop = true;
      await _killSingBox();

      await Future.delayed(const Duration(seconds: 1));

      if (_plaintextPath == null || !await File(_plaintextPath!).exists()) {
        throw Exception('No config available for recovery');
      }

      _isNormalStop = false;
      _consecutiveFailures = 0;
      _lastSuccessfulPing = DateTime.now();

      final singBoxFile = File(_singBoxPath);
      if (!await singBoxFile.exists()) {
        throw Exception('sing-box not found at $_singBoxPath');
      }

      await Process.run('chmod', ['+x', _singBoxPath]);

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', _plaintextPath!],
        workingDirectory: _resourcesDir,
      );

      _singBoxProcess!.stdout
          .transform(utf8.decoder)
          .listen((data) => _log('sing-box: $data'));

      _singBoxProcess!.stderr.transform(utf8.decoder).listen((data) async {
        await _log('sing-box ERR: $data');
        if (data.contains('authentication failed, status code: 403')) {
          _auth403Count++;
          _reset403Counter();
          if (_auth403Count >= 5) {
            await _handleSubscriptionExpired();
          }
        }
      });

      await Future.delayed(const Duration(seconds: 3));
      final isRunning = await _isSingBoxRunning();
      if (!isRunning) throw Exception('sing-box not running after recovery');

      _isConnected = true;
      _statusController.add(true);

      await MacosNotificationService.showToast(
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
      await _log('Failed to restart VPN after recovery: $e');
      _isNormalStop = false;
      _wasNetworkLost = false;

      await MacosNotificationService.showToast(
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

  /// Check for active non-VPN network interface on macOS using ifconfig
  static Future<bool> _checkForAnyNetwork() async {
    try {
      final result = await Process.run('ifconfig', []);
      final output = result.stdout.toString();

      final lines = output.split('\n');
      for (final line in lines) {
        if (line.contains('inet ') &&
            !line.contains('127.0.0.1') &&
            !line.contains('172.19.')) {
          await _log('Found active network: ${line.trim()}');
          return true;
        }
      }

      await _log('No active non-VPN network interfaces found');
      return false;
    } catch (e) {
      await _log('Error checking network interfaces: $e');
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
      _auth403Count = 0;
      _auth403Timer?.cancel();
      _isHandlingSubscriptionExpiry = false;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_seen_at', DateTime.now().millisecondsSinceEpoch);

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      await _log('DEBUG deviceId: $deviceId');
      await _log('DEBUG apiKey: $apiKey');
      await _log('DEBUG email: ${await AuthService.getStoredEmail()}');

      if (deviceId == null || apiKey == null) {
        throw Exception('Device not registered. Please login again.');
      }

      await _log('Fetching credentials for device: $deviceId');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode == 401) {
        final errorData = json.decode(response.body);
        throw Exception(errorData['message'] ??
            'Device not registered. Please login again.');
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
        throw Exception(
            errorData['message'] ?? 'Maximum active devices reached');
      }

      if (response.statusCode != 200) {
        try {
          final errorData = json.decode(response.body);
          throw Exception(errorData['message'] ??
              'Failed to connect: ${response.statusCode}');
        } catch (_) {
          throw Exception('Failed to connect: ${response.statusCode}');
        }
      }

      final data = json.decode(response.body);
      final credentials = data['credentials'];

      if (credentials == null || credentials['wireguard'] == null) {
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

      await _log('Resources dir: $_resourcesDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      final tempDir = await getTemporaryDirectory();
      _plaintextPath = '${tempDir.path}/config.json';

      // Write plaintext config only — no encryption on macOS
      // (SecureConfigService uses keychain APIs not available on unsigned builds)
      await File(_plaintextPath!).writeAsString(configJson);

      await Process.run('chmod', ['+x', _singBoxPath]);

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', _plaintextPath!],
        workingDirectory: _resourcesDir,
      );

      await _log('sing-box started with pid: ${_singBoxProcess!.pid}');

      _singBoxProcess!.stdout
          .transform(utf8.decoder)
          .listen((data) => _log('sing-box: $data'));

      _singBoxProcess!.stderr.transform(utf8.decoder).listen((data) async {
        await _log('sing-box ERR: $data');
        if (data.contains('authentication failed, status code: 403')) {
          _auth403Count++;
          _reset403Counter();
          if (_auth403Count >= 5) {
            await _log('SUBSCRIPTION EXPIRED DETECTED (403 from sing-box)');
            await _handleSubscriptionExpired();
          }
        }
      });

      _singBoxProcess!.exitCode.then((code) async {
        await _log('sing-box exited with code: $code');
        await _deleteFile(_plaintextPath);
        _plaintextPath = null;

        if (_isConnected) {
          _isConnected = false;
          _statusController.add(false);

          if (!_isNormalStop && code != 0) {
            await MacosNotificationService.showToast(
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
      await _log('macOS VPN error: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopVpn() async {
    await _log('stopVpn called');

    _isNormalStop = true;
    _auth403Count = 0;
    _auth403Timer?.cancel();
    _isHandlingSubscriptionExpiry = false;

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
        await _log('Backend notified of disconnection');
      }
    } catch (e) {
      await _log('Failed to notify backend: $e');
    }

    await _killSingBox();
    await _deleteFile(_plaintextPath);
    _plaintextPath = null;

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
  Future<VpnEvent?> checkForDeathEvents() async => null;

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
        final jsonData = jsonDecode(response.body);
        final status = jsonData['subscription']['status'] as String;
        return status != 'active' ? 'expired' : 'active';
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        return 'expired';
      }
      return 'unknown';
    } catch (e) {
      await _log('Subscription check error: $e');
      return 'unknown';
    }
  }

  @override
  Future<void> reconnectVpn() async {
    await _log('Attempting to reconnect...');
    final subscriptionStatus = await checkSubscription();

    if (subscriptionStatus == 'expired') {
      await _log('Subscription expired - blocking reconnect');
      throw Exception('subscription_expired');
    }

    await startVpn();
  }
}
