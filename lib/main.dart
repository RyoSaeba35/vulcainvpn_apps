import 'package:flutter/material.dart';
import 'services/auth_service.dart';
import 'services/api_service.dart';
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
import 'package:flutter_svg/flutter_svg.dart';

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

// ─── Home Page with Bottom Navigation ────────────────────────────────────────

class VpnHomePage extends StatefulWidget {
  final VoidCallback onLogout;

  const VpnHomePage({super.key, required this.onLogout});

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  int _selectedIndex = 0;

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

    await Future.delayed(const Duration(seconds: 3));
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
    for (int i = 0; i < 8; i++) {
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
      await Future.delayed(const Duration(seconds: 3));
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
    await Future.delayed(const Duration(seconds: 4));
    for (int attempt = 0; attempt < 8; attempt++) {
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
      _fetchCurrentIpAndLocationWithRetry();
    }
  }

  String _formatTime(int seconds) {
    int hours = seconds ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int secs = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    final List<Widget> pages = [
      _buildHomeTab(loc),
      const _SubscriptionTab(),
      _SettingsTab(
        onLogout: widget.onLogout,
        vpnService: _vpnService,
        connectionState: _connectionState,
        loc: loc,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MyColors.myOrange,
        title: Text(loc.appTitle),
        centerTitle: true,
      ),
      body: pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        selectedItemColor: MyColors.myOrange,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.card_membership_outlined),
            activeIcon: Icon(Icons.card_membership),
            label: 'Subscription',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  // ─── VPN Tab (your existing working UI) ─────────────────────────────────────

  Widget _buildHomeTab(AppLocalizations loc) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset(
            _connectionState == 'connected'
              ? 'assets/icons/france_filled.svg'
              : 'assets/icons/france_outline.svg',
            width: 140,
            height: 140,
            colorFilter: ColorFilter.mode(
              _connectionState == 'connected'
                  ? Colors.green
                  : _connectionState == 'connecting'
                      ? MyColors.myOrange
                      : Colors.grey,
              BlendMode.srcIn,
            ),
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
    );
  }
}

// ─── Subscription Tab ─────────────────────────────────────────────────────────

class _SubscriptionTab extends StatefulWidget {
  const _SubscriptionTab();

  @override
  State<_SubscriptionTab> createState() => _SubscriptionTabState();
}

class _SubscriptionTabState extends State<_SubscriptionTab> {
  Map<String, dynamic>? _subscriptionData;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  Future<void> _loadSubscription() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await ApiService.fetchSubscription();
      setState(() {
        _subscriptionData = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load subscription info.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: MyColors.myOrange),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadSubscription,
              style: ElevatedButton.styleFrom(
                  backgroundColor: MyColors.myOrange),
              child: const Text('Retry',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    final sub = _subscriptionData?['subscription'];
    if (sub == null) {
      return const Center(child: Text('No subscription data available.'));
    }

    final plan = sub['plan'] ?? {};
    final server = sub['server'] ?? {};
    final devices = sub['devices'] ?? {};
    final expiresAt = DateTime.tryParse(sub['expires_at'] ?? '');
    final daysRemaining =
        expiresAt != null ? expiresAt.difference(DateTime.now()).inDays : 0;
    final activeDevices = devices['active'] ?? 0;
    final totalDevices = devices['total'] ?? 0;
    final maxDevices = devices['max'] ?? 3;

    return RefreshIndicator(
      onRefresh: _loadSubscription,
      color: MyColors.myOrange,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _InfoCard(
            title: 'Subscription',
            icon: Icons.card_membership,
            children: [
              _InfoRow(
                label: 'Plan',
                value: '${plan['name'] ?? '-'} — ${plan['interval'] ?? '-'}',
              ),
              _InfoRow(
                label: 'Reference',
                value: sub['name'] ?? '-',
              ),
              _InfoRow(
                label: 'Status',
                value: sub['status'] ?? '-',
                valueColor:
                    sub['status'] == 'active' ? Colors.green : Colors.red,
              ),
              _InfoRow(
                label: 'Expires',
                value: expiresAt != null
                    ? '${expiresAt.day}/${expiresAt.month}/${expiresAt.year}'
                    : '-',
              ),
              _InfoRow(
                label: 'Days remaining',
                value: '$daysRemaining days',
                valueColor: daysRemaining < 7 ? Colors.red : Colors.green,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(
            title: 'Server',
            icon: Icons.dns_outlined,
            children: [
              _InfoRow(label: 'Location', value: server['name'] ?? '-'),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(
            title: 'Devices',
            icon: Icons.devices_outlined,
            children: [
              _InfoRow(
                label: 'Active connections',
                value: '$activeDevices / $maxDevices',
                valueColor:
                    activeDevices >= maxDevices ? Colors.red : Colors.green,
              ),
              _InfoRow(
                label: 'Registered devices',
                value: '$totalDevices',
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: maxDevices > 0 ? activeDevices / maxDevices : 0,
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    activeDevices >= maxDevices
                        ? Colors.red
                        : MyColors.myOrange,
                  ),
                  minHeight: 8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Settings Tab ─────────────────────────────────────────────────────────────

class _SettingsTab extends StatelessWidget {
  final VoidCallback onLogout;
  final VpnService vpnService;
  final String connectionState;
  final AppLocalizations loc;

  const _SettingsTab({
    required this.onLogout,
    required this.vpnService,
    required this.connectionState,
    required this.loc,
  });

  void _showLanguageDialog(BuildContext context) {
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

  void _showLogoutDialog(BuildContext context) {
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
              if (connectionState == 'connected') {
                await vpnService.stopVpn();
              }
              onLogout();
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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _InfoCard(
          title: 'Account',
          icon: Icons.person_outline,
          children: [
            FutureBuilder<String?>(
              future: AuthService.getStoredEmail(),
              builder: (context, snapshot) {
                return _InfoRow(
                  label: 'Email',
                  value: snapshot.data ?? '—',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          title: 'Preferences',
          icon: Icons.tune_outlined,
          children: [
            InkWell(
              onTap: () => _showLanguageDialog(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      loc.language,
                      style:
                          TextStyle(color: Colors.grey[600], fontSize: 14),
                    ),
                    Row(
                      children: [
                        Text(
                          Localizations.localeOf(context).languageCode == 'fr'
                              ? '🇫🇷 Français'
                              : '🇬🇧 English',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: Colors.grey[400]),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton.icon(
            onPressed: () => _showLogoutDialog(context),
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text(
              'Logout',
              style: TextStyle(
                color: Colors.red,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.red),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _InfoCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: MyColors.myOrange, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}
