import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'vpn_service.dart';
import '../config/vpn_config.dart';

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  static String get _logPath => '$_exeDir\\vpn_log.txt';

  static Future<void> _log(String message) async {
    final logFile = File(_logPath);
    // Keep log under 1MB — delete if too large
    if (await logFile.exists()) {
      final size = await logFile.length();
      if (size > 1024 * 1024) {
        await logFile.delete();
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
      await _log('exe dir: $_exeDir');
      await _log('sing-box path: $_singBoxPath');
      await _log('sing-box exists: ${File(_singBoxPath).existsSync()}');

      final tempDir = await getTemporaryDirectory();
      final configFile = File('${tempDir.path}\\config.json');
      await configFile.writeAsString(vpnConfig);
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
