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
      final tempDir = await getTemporaryDirectory();
      final configFile = File('${tempDir.path}\\config.json');
      await configFile.writeAsString(vpnConfig);

      _singBoxProcess = await Process.start(
        _singBoxPath,
        ['run', '-c', configFile.path],
      );

      // Log output so we can see what's happening
      _singBoxProcess!.stdout
          .transform(SystemEncoding().decoder)
          .listen((data) => print('sing-box: $data'));
      _singBoxProcess!.stderr
          .transform(SystemEncoding().decoder)
          .listen((data) => print('sing-box ERR: $data'));

      _singBoxProcess!.exitCode.then((code) {
        print('sing-box exited with code: $code');
        // Delete config when process exits
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
