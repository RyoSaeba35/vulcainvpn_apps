import 'package:flutter/material.dart';
import 'services/auth_service.dart';
import 'screens/login_screen.dart';
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
      home: const AuthGate(),
    );
  }
}

// ─── Auth Gate ───────────────────────────────────────────────────────────────

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isLoading = true;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final loggedIn = await AuthService.isLoggedIn();
    if (mounted) {
      setState(() {
        _isLoggedIn = loggedIn;
        _isLoading = false;
      });
    }
  }

  void _onLoginSuccess() {
    setState(() => _isLoggedIn = true);
  }

  void _onLogout() async {
    await AuthService.logout();
    if (mounted) {
      setState(() => _isLoggedIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show splash while checking stored token
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: MyColors.myBrown,
        body: Center(
          child: CircularProgressIndicator(color: MyColors.myOrange),
        ),
      );
    }

    if (!_isLoggedIn) {
      return LoginScreen(onLoginSuccess: _onLoginSuccess);
    }

    return VpnHomePage(onLogout: _onLogout);
  }
}

// ─── Home Page ───────────────────────────────────────────────────────────────

class VpnHomePage extends StatefulWidget {
  final VoidCallback onLogout;

  const VpnHomePage({super.key, required this.onLogout});

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
  TrayWindowService? _trayService;

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
        _fetchUntilIpChanges(_currentIp);
      } else {
        _fetchCurrentIpAndLocationWithRetry();
      }
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

  Future<void> _fetchUntilIpChanges(String previousIp) async {
    setState(() => _isLoadingIp = true);

    const maxWait = Duration(seconds: 20);
    final deadline = DateTime.now().add(maxWait);

    for (int i = 0; i < 10; i++) {
      if (!mounted) return;
      if (DateTime.now().isAfter(deadline)) break;

      await Future.delayed(const Duration(seconds: 3));

      try {
        final result = await IpService.getPublicIpAndLocation();
        final ip = result['ip'];

        if (ip != null && ip != 'Unknown' && ip != previousIp) {
          if (!mounted) return;
          setState(() {
            _currentIp = ip;
            _currentCountry = result['country'] ?? '';
            _currentCountryCode = result['countryCode'] ?? '';
            _isLoadingIp = false;
          });
          return;
        }
      } catch (e) {
        print('_fetchUntilIpChanges attempt $i failed: $e');
      }
    }

    if (!mounted) return;
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
      setState(() => _connectionState = 'connecting');

      final ipBeforeConnect = _currentIp;

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
          _fetchUntilIpChanges(ipBeforeConnect);
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
          String message;

          if (Platform.isAndroid &&
              e is PlatformException &&
              (e.code == 'NOTIFICATION_PERMISSION_DENIED' ||
                  e.message?.contains('null') == true)) {
            message =
                'Notification permission is required for the VPN to stay active. Please allow it and try again.';
          } else if (Platform.isAndroid &&
              e is PlatformException &&
              (e.code == 'VPN_PERMISSION_DENIED' || e.details == null)) {
            message =
                'VPN permission is required to protect your connection. Please allow it and try again.';
          } else {
            message = 'Failed to start VPN: $e';
          }

          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Connection Error'),
              content: Text(message),
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

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // Disconnect VPN before logging out
              if (_connectionState == 'connected') {
                await _vpnService.stopVpn();
              }
              widget.onLogout();
            },
            child: const Text(
              'Logout',
              style: TextStyle(color: Colors.red),
            ),
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
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _showLogoutDialog,
            tooltip: 'Logout',
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
                  '${loc.location}: $_currentCountry${Platform.isWindows ? '' : ' ${_getFlag(_currentCountryCode)}'} ',
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
