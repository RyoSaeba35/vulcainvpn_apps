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

  @override
  Stream<bool> get statusStream => _statusController.stream;

  @override
  Future<bool> startVpn() async {
    try {
      await _log('startVpn called');

      // ⭐ Step 1: Get device credentials
      final deviceId = await AuthService.getDeviceId();
      final apiKey = await AuthService.getApiKey();

      if (deviceId == null || apiKey == null) {
        await _log('Error: Device not registered');
        return false;
      }

      await _log('Fetching credentials for device: $deviceId');

      // ⭐ Step 2: Call /api/connect to get credentials
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

      // ⭐ Step 3: Build dynamic config
      final config = VpnConfigService.buildConfig(
        wireguard: credentials['wireguard'],
        hysteria2: credentials['hysteria2'],
        shadowsocks: credentials['shadowsocks'],
      );

      // ⭐ Step 4: Convert to JSON string
      final configJson = VpnConfigService.toJsonString(config);
      await _log('Config built successfully');

      // ⭐ Step 5: Write config to temp file
      await _log('exe dir: $_exeDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      final tempDir = await getTemporaryDirectory();
      final configFile = File('${tempDir.path}\\config.json');
      await configFile.writeAsString(configJson);
      await _log('config written to: ${configFile.path}');

      // ⭐ Step 6: Start sing-box process
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

      _singBoxProcess!.exitCode.then((code) {
        _log('sing-box exited with code: $code');
        configFile.delete();
        if (_isConnected) {
          _isConnected = false;
          _statusController.add(false);
        }
      });

      await Future.delayed(const Duration(seconds: 2));
      _isConnected = true;
      _statusController.add(true);
      return true;
    } catch (e) {
      await _log('Windows VPN error: $e');
      return false;
    }
  }

  @override
  Future<void> stopVpn() async {
    await _log('stopVpn called');

    // ⭐ Notify backend of disconnection
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

    // Kill by reference if we have it
    _singBoxProcess?.kill();
    _singBoxProcess = null;

    // Also kill by name in case process was started in a previous session
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
