import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'vpn_service.dart';
import '../config/vpn_config.dart';

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;

  static final _logFile = File('C:\\Users\\Pierre\\Downloads\\windows-build\\vpn_log.txt');

  static Future<void> _log(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    await _logFile.writeAsString('$timestamp: $message\n', mode: FileMode.append);
  }

  static String get _singBoxPath {
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    final arch2 = Platform.environment['PROCESSOR_ARCHITEW6432'] ?? '';
    final isArm = arch.toUpperCase().contains('ARM') ||
                  arch2.toUpperCase().contains('ARM');

    final binary = isArm ? 'sing-box-arm64.exe' : 'sing-box-amd64.exe';
    return '$exeDir\\$binary';
  }

  @override
  Stream<bool> get statusStream => _statusController.stream;

  @override
  Future<bool> startVpn() async {
    try {
      await _log('startVpn called');
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
    _singBoxProcess?.kill();
    _singBoxProcess = null;
    _isConnected = false;
    _statusController.add(false);
  }

  @override
  Future<bool> checkNotificationPermission() async => true;
}
