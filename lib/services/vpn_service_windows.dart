import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'vpn_service.dart';
import 'vpn_config_service.dart';
import 'auth_service.dart';

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;

  static Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 90);

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

  // ⭐ FIXED: Check both process names separately (wildcards don't work in tasklist filters!)
  static Future<bool> _isProcessRunning() async {
    try {
      // Check for AMD64 version
      var result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq sing-box-amd64.exe']);
      var output = result.stdout.toString();
      if (output.contains('sing-box-amd64.exe')) {
        return true;
      }

      // Check for ARM64 version
      result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq sing-box-arm64.exe']);
      output = result.stdout.toString();
      if (output.contains('sing-box-arm64.exe')) {
        return true;
      }

      return false;
    } catch (e) {
      await _log('Failed to check process: $e');
      return false;
    }
  }

  // ⭐ NEW: Public method for health checks
  Future<bool> checkVpnState() async {
    return await _isProcessRunning();
  }

  static Future<void> _startHeartbeat() async {
    _stopHeartbeat();
    await _log('🟢 Starting heartbeat timer (every ${_heartbeatInterval.inSeconds}s)');

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (timer) async {
      await _sendHeartbeat();
    });

    await _sendHeartbeat();
  }

  static void _stopHeartbeat() {
    if (_heartbeatTimer != null) {
      _log('🔴 Stopping heartbeat timer');
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    }
  }

  static Future<void> _sendHeartbeat() async {
    try {
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('⚠️  Cannot send heartbeat: no credentials');
        return;
      }

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/heartbeat/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        await _log('💓 Heartbeat sent successfully');
      } else {
        await _log('⚠️  Heartbeat failed: ${response.statusCode}');
      }
    } catch (e) {
      await _log('⚠️  Heartbeat error: $e');
    }
  }

  @override
  Stream<bool> get statusStream => _statusController.stream;

  @override
  Future<bool> startVpn() async {
    try {
      await _log('startVpn called');

      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('Error: Device not registered');
        return false;
      }

      await _log('Fetching credentials for device: $deviceId');

      final response = await http.post(
        Uri.parse('https://api.vulcainvpn.com/api/connect/$deviceId'),
        headers: {'X-Api-Key': apiKey},
      );

      if (response.statusCode != 200) {
        await _log('Failed to get credentials: ${response.statusCode}');
        return false;
      }

      final data = json.decode(response.body);
      final credentials = data['credentials'];
      await _log('Credentials received');

      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      final configJson = VpnConfigService.toJsonString(config);
      await _log('Config built successfully');

      await _log('exe dir: $_exeDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      final tempDir = await getTemporaryDirectory();
      final configFile = File('${tempDir.path}\\config.json');
      await configFile.writeAsString(configJson);
      await _log('config written to: ${configFile.path}');

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', configFile.path],
      );
      await _log('process started with pid: ${_singBoxProcess!.pid}');

      _singBoxProcess!.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box: $data'));
      _singBoxProcess!.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) => _log('sing-box ERR: $data'));

      _singBoxProcess!.exitCode.then((code) async {
        await _log('sing-box exited with code: $code');
        configFile.delete();
        if (_isConnected) {
          _isConnected = false;
          _statusController.add(false);
          _stopHeartbeat();
        }
      });

      await Future.delayed(const Duration(seconds: 2));
      _isConnected = true;
      _statusController.add(true);

      await _startHeartbeat();

      return true;
    } catch (e) {
      await _log('Windows VPN error: $e');
      return false;
    }
  }

  @override
  Future<void> stopVpn() async {
    await _log('stopVpn called');

    _stopHeartbeat();

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

    _singBoxProcess?.kill();
    _singBoxProcess = null;

    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-amd64.exe']);
      await Process.run('taskkill', ['/F', '/IM', 'sing-box-arm64.exe']);
    } catch (e) {
      await _log('taskkill error: $e');
    }

    _isConnected = false;
    _statusController.add(false);
  }

  @override
  Future<bool> checkNotificationPermission() async => true;
}
