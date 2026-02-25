import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'vpn_service.dart';
import '../config/vpn_config.dart';

class WindowsVpnService extends VpnService {
  static Process? _singBoxProcess;
  static final _statusController = StreamController<bool>.broadcast();
  static bool _isConnected = false;

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
      // Write hardcoded config to temp file
      final tempDir = await getTemporaryDirectory();
      final configFile = File('${tempDir.path}\\config.json');
      await configFile.writeAsString(vpnConfig);

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', configFile.path],
      );

      await configFile.delete();

      _singBoxProcess!.exitCode.then((_) {
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
      print('Windows VPN error: $e');
      return false;
    }
  }

  @override
  Future<void> stopVpn() async {
    _singBoxProcess?.kill();
    _singBoxProcess = null;
    _isConnected = false;
    _statusController.add(false);
  }

  @override
  Future<bool> checkNotificationPermission() async => true;
}
