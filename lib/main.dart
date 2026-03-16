import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'colors.dart';
import 'dart:async';
import 'dart:io';
import 'l10n/app_localizations.dart';
import 'services/ip_service.dart';
import 'services/vpn_service.dart';
import 'services/tray_window_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      skipTaskbar: false,
      title: 'Vulcain VPN',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static void setLocale(BuildContext context, Locale newLocale) {
    _MyAppState? state = context.findAncestorStateOfType<_MyAppState>();
    state?.setLocale(newLocale);
  }
}

class _MyAppState extends State<MyApp> {
  Locale _locale = const Locale('en');

  void setLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vulcain VPN',
      locale: _locale,
      supportedLocales: const [
        Locale('en', ''),
        Locale('fr', ''),
      ],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: MyColors.myOrange),
        useMaterial3: false,
      ),
      home: const VpnHomePage(),
    );
  }
}

class VpnHomePage extends StatefulWidget {
  const VpnHomePage({super.key});

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  String _connectionState = 'disconnected';
  int _connectionSeconds = 0;
  Timer? _timer;
  Timer? _ipCheckTimer;
  String _currentIp = '';
  String _currentCountry = '';
  String _currentCountryCode = '';
  bool _isLoadingIp = true;
  StreamSubscription<bool>? _vpnSubscription;
  TrayWindowService? _trayService; // null on Android/iOS

  late final VpnService _vpnService = VpnService.instance;

  @override
  void initState() {
    super.initState();
    _initTrayIfWindows();
    _init();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ipCheckTimer?.cancel();
    _vpnSubscription?.cancel();
    _trayService?.dispose();
    super.dispose();
  }

  Future<void> _initTrayIfWindows() async {
    if (!Platform.isWindows) return;
    _trayService = TrayWindowService(
      onToggleConnection: _toggleConnection,
      onQuit: _quitApp,
    );
    await _trayService!.init();
    await _checkExistingVpn();
  }

  Future<void> _quitApp() async {
    if (_connectionState == 'connected') {
      await _vpnService.stopVpn();
    }
    if (Platform.isWindows) {
      await windowManager.destroy();
    }
  }

  Future<void> _checkExistingVpn() async {
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq sing-box-amd64.exe', '/NH'],
      );
      if (result.stdout.toString().contains('sing-box-amd64.exe')) {
        setState(() {
          _connectionState = 'connected';
          _connectionSeconds = 0;
          _timer?.cancel();
          _timer = Timer.periodic(const Duration(seconds: 1), (t) {
            setState(() => _connectionSeconds++);
          });
        });
        await _trayService?.updateState(true);
      }
    } catch (e) {
      print('Could not check existing VPN: $e');
    }
  }

  Future<void> _init() async {
    if (Platform.isWindows) {
      await _checkAdminRights();
    }

    await Future.delayed(const Duration(seconds: 5));
    _fetchCurrentIpAndLocation();

    _vpnSubscription = _vpnService.statusStream.listen((isConnected) async {
      if (!mounted) return;
      setState(() {
        if (isConnected) {
          _connectionState = 'connected';
          _connectionSeconds = 0;
          _timer?.cancel();
          _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
            setState(() => _connectionSeconds++);
          });
        } else {
          _connectionState = 'disconnected';
          _connectionSeconds = 0;
          _timer?.cancel();
        }
      });

      await _trayService?.updateState(isConnected);

      if (isConnected) {
        await Future.delayed(const Duration(seconds: 5));
      }
      _fetchCurrentIpAndLocationWithRetry();
    });
  }

  Future<void> _checkAdminRights() async {
    try {
      final result = await Process.run('net', ['session'], runInShell: true);
      if (result.exitCode != 0 && mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Admin Rights Required'),
            content: const Text(
              'Managing VPN tunnels on Windows requires administrator privileges. '
              'Please restart the app as administrator.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      print('Admin check failed: $e');
    }
  }

  Future<void> _fetchCurrentIpAndLocation() async {
    setState(() => _isLoadingIp = true);
    for (int i = 0; i < 5; i++) {
      try {
        final result = await IpService.getPublicIpAndLocation();
        if (result['ip'] != 'Unknown') {
          setState(() {
            _currentIp = result['ip'];
            _currentCountry = result['country'];
            _currentCountryCode = result['countryCode'];
            _isLoadingIp = false;
          });
          return;
        }
      } catch (e) {
        print('Attempt $i failed: $e');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    setState(() {
      _currentIp = 'Unknown';
      _currentCountry = '';
      _currentCountryCode = '';
      _isLoadingIp = false;
    });
  }

  Future<void> _fetchCurrentIpAndLocationWithRetry() async {
    setState(() => _isLoadingIp = true);
    await Future.delayed(const Duration(seconds: 2));
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await IpService.getPublicIpAndLocation();
        if (result['ip'] != 'Unknown') {
          setState(() {
            _currentIp = result['ip'];
            _currentCountry = result['country'];
            _currentCountryCode = result['countryCode'];
            _isLoadingIp = false;
          });
          return;
        }
      } catch (e) {
        print('Attempt ${attempt + 1} failed: $e');
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    setState(() {
      _currentIp = 'Unknown';
      _currentCountry = '';
      _currentCountryCode = '';
      _isLoadingIp = false;
    });
  }

  String _getFlag(String countryCode) {
    if (countryCode.isEmpty) return '';
    return String.fromCharCodes(
      Runes(countryCode.toUpperCase().replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => String.fromCharCode(
          match.group(0)!.codeUnitAt(0) + 127397,
        ),
      )),
    );
  }

  void _toggleConnection() async {
    if (_connectionState == 'disconnected') {
      if (Platform.isAndroid) {
        final hasPermission = await _vpnService.checkNotificationPermission();
        if (!hasPermission) {
          await _showEnableNotificationsDialog();
          return;
        }
      }

      setState(() => _connectionState = 'connecting');

      try {
        final success = await _vpnService.startVpn();
        if (success) {
          setState(() {
            _connectionState = 'connected';
            _connectionSeconds = 0;
          });
          _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
            setState(() => _connectionSeconds++);
          });
        } else {
          setState(() => _connectionState = 'disconnected');
          if (mounted) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Connection Failed'),
                content: const Text(
                    'Failed to start VPN. Please check permissions.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
        }
      } catch (e) {
        setState(() => _connectionState = 'disconnected');
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Connection Error'),
              content: Text('Failed to start VPN: $e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    } else {
      await _vpnService.stopVpn();
      _timer?.cancel();
      setState(() {
        _connectionState = 'disconnected';
        _connectionSeconds = 0;
      });
      await Future.delayed(const Duration(seconds: 2));
      _fetchCurrentIpAndLocation();
    }
  }

  Future<String> _getPackageName() async {
    return await MethodChannel('com.vulcain.vpn/package')
        .invokeMethod('getPackageName');
  }

  Future<void> _showEnableNotificationsDialog() async {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Notifications Required"),
        content: const Text(
          "Android requires notifications for VPN services. "
          "Please enable notifications in settings.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final packageName = await _getPackageName();
                final url =
                    Uri.parse('android.settings.APP_NOTIFICATION_SETTINGS')
                        .replace(queryParameters: {'package': packageName});
                if (await canLaunchUrl(url)) await launchUrl(url);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open settings: $e')),
                );
              }
            },
            child: const Text("Open Settings"),
          ),
        ],
      ),
    );
  }

  String _formatTime(int seconds) {
    int hours = seconds ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _showLanguageDialog() {
    final loc = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(loc.language),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(loc.english),
                leading: const Text('🇬🇧', style: TextStyle(fontSize: 24)),
                onTap: () {
                  MyApp.setLocale(context, const Locale('en'));
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: Text(loc.french),
                leading: const Text('🇫🇷', style: TextStyle(fontSize: 24)),
                onTap: () {
                  MyApp.setLocale(context, const Locale('fr'));
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MyColors.myOrange,
        title: Text(loc.appTitle),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showLanguageDialog,
            tooltip: loc.settings,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _connectionState == 'connected'
                  ? Icons.shield
                  : Icons.shield_outlined,
              size: 140,
              color: _connectionState == 'connected'
                  ? Colors.green
                  : _connectionState == 'connecting'
                      ? MyColors.myOrange
                      : Colors.grey,
            ),
            const SizedBox(height: 40),
            Text(
              _connectionState == 'connected'
                  ? loc.connected
                  : _connectionState == 'connecting'
                      ? loc.connecting
                      : loc.disconnected,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 15),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${loc.location}: $_currentCountry ${_getFlag(_currentCountryCode)} ',
                  style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                ),
                if (_isLoadingIp)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    '($_currentIp)',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[700],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            if (_connectionState == 'connected')
              Padding(
                padding: const EdgeInsets.only(top: 15),
                child: Text(
                  '${loc.duration}: ${_formatTime(_connectionSeconds)}',
                  style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                ),
              ),
            if (_connectionState == 'connected')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  loc.secureConnection,
                  style: TextStyle(fontSize: 16, color: Colors.green[700]),
                ),
              ),
            const SizedBox(height: 60),
            ElevatedButton(
              onPressed:
                  _connectionState == 'connecting' ? null : _toggleConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: _connectionState == 'connected'
                    ? Colors.red
                    : MyColors.myOrange,
                disabledBackgroundColor: Colors.grey,
                padding: const EdgeInsets.symmetric(
                  horizontal: 60,
                  vertical: 22,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 5,
              ),
              child: Text(
                _connectionState == 'connected'
                    ? loc.disconnect
                    : _connectionState == 'connecting'
                        ? loc.connectingBtn
                        : loc.connect,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
