import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:io';
import '../colors.dart';
import '../l10n/app_localizations.dart';
import '../services/ip_service.dart';
import '../services/vpn_service.dart';
import '../services/tray_window_service.dart';
import '../services/vpn_service_android.dart';
import 'tabs/home_tab.dart';
import 'tabs/subscription_tab.dart';
import 'tabs/settings_tab.dart';

class VpnHomePage extends StatefulWidget {
  final VoidCallback onLogout;

  const VpnHomePage({super.key, required this.onLogout});

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  int _selectedIndex = 0;

  String _connectionState = 'disconnected';

  // ⭐ CHANGED: Use timestamp-based duration instead of counter
  DateTime? _vpnStartTime;
  Duration _elapsedTime = Duration.zero;
  Timer? _displayTimer;

  Timer? _ipCheckTimer;
  String _currentIp = '';
  String _currentCountry = '';
  String _currentCountryCode = '';
  bool _isLoadingIp = true;
  StreamSubscription<bool>? _vpnSubscription;
  TrayWindowService? _trayService;

  late final VpnService _vpnService = VpnService.instance;

  // ⭐ CHANGED: Computed property instead of _connectionSeconds
  int get _connectionSeconds => _elapsedTime.inSeconds;

  @override
  void initState() {
    super.initState();
    _initTrayIfWindows();
    _init();
  }

  @override
  void dispose() {
    _displayTimer?.cancel();
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
          // ⭐ CHANGED: Start timestamp-based timer instead
          _vpnStartTime = DateTime.now();
          _startDisplayTimer();
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

    if (Platform.isAndroid) {
      await _restoreVpnState();
    }

    await Future.delayed(const Duration(seconds: 3));
    _fetchCurrentIpAndLocation();

    _vpnSubscription = _vpnService.statusStream.listen((isConnected) async {
      if (!mounted) return;
      setState(() {
        if (isConnected) {
          _connectionState = 'connected';
          // ⭐ CHANGED: Set start time instead of counter
          if (_vpnStartTime == null) {
            _vpnStartTime = DateTime.now();
          }
          _startDisplayTimer();
        } else {
          _connectionState = 'disconnected';
          _stopDisplayTimer();
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

  // ⭐ NEW: Start display timer (updates UI every second)
  void _startDisplayTimer() {
    _displayTimer?.cancel();
    _displayTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_vpnStartTime != null && mounted) {
        setState(() {
          _elapsedTime = DateTime.now().difference(_vpnStartTime!);
        });
      }
    });
  }

  // ⭐ NEW: Stop display timer and reset
  void _stopDisplayTimer() {
    _displayTimer?.cancel();
    _vpnStartTime = null;
    _elapsedTime = Duration.zero;
  }

  // ⭐ NEW: Load VPN start time from native
  Future<void> _loadVpnStartTime() async {
    if (!Platform.isAndroid) return;

    try {
      final startTimeMs = await (VpnService.instance as AndroidVpnService).getConnectionStartTimeMs();
      if (startTimeMs != null && startTimeMs > 0) {
        setState(() {
          _vpnStartTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
        });
        _startDisplayTimer();
      }
    } catch (e) {
      print('Failed to load VPN start time: $e');
    }
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

  void _toggleConnection() async {
    if (_connectionState == 'disconnected') {
      setState(() => _connectionState = 'connecting');

      final ipBeforeConnect = _currentIp;

      try {
        final success = await _vpnService.startVpn();
        if (success) {
          setState(() {
            _connectionState = 'connected';
            // ⭐ CHANGED: Set start time
            _vpnStartTime = DateTime.now();
          });
          _startDisplayTimer();
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
          String title = 'Connection Error';
          String message;

          final errorString = e.toString();

          if (errorString.contains('Maximum active devices reached')) {
            title = 'Device Limit Reached';
            message = 'You can only connect 3 devices at the same time.\n\n'
                    'Please disconnect another device and try again.';
          } else if (errorString.contains('Device not registered')) {
            title = 'Not Registered';
            message = 'Your device is not registered. Please logout and login again.';
          } else if (Platform.isAndroid &&
              e is PlatformException &&
              (e.code == 'NOTIFICATION_PERMISSION_DENIED' ||
                  e.message?.contains('null') == true)) {
            title = 'Permission Required';
            message = 'Notification permission is required for the VPN to stay active.\n\n'
                    'Please allow it and try again.';
          } else if (Platform.isAndroid &&
              e is PlatformException &&
              (e.code == 'VPN_PERMISSION_DENIED' || e.details == null)) {
            title = 'Permission Required';
            message = 'VPN permission is required to protect your connection.\n\n'
                    'Please allow it and try again.';
          } else if (errorString.contains('Failed to connect: 429')) {
            title = 'Device Limit Reached';
            message = 'Maximum number of active connections reached.\n\n'
                    'Please disconnect another device first.';
          } else {
            message = 'Failed to start VPN.\n\n'
                    'Error: ${errorString.replaceAll('Exception: ', '')}';
          }

          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(title),
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
    } else if (_connectionState == 'connected') {
      setState(() => _connectionState = 'disconnecting');

      await _vpnService.stopVpn();

      // ⭐ CHANGED: Stop timer and reset
      _stopDisplayTimer();

      setState(() {
        _connectionState = 'disconnected';
      });

      _fetchCurrentIpAndLocationWithRetry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    final List<Widget> pages = [
      HomeTab(
        connectionState: _connectionState,
        connectionSeconds: _connectionSeconds,
        currentIp: _currentIp,
        currentCountry: _currentCountry,
        currentCountryCode: _currentCountryCode,
        isLoadingIp: _isLoadingIp,
        onToggleConnection: _toggleConnection,
        loc: loc,
      ),
      const SubscriptionTab(),
      SettingsTab(
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

  // ⭐ UPDATED: Restore VPN state and load start time
  Future<void> _restoreVpnState() async {
    if (!Platform.isAndroid) return;

    try {
      final isRunning = await (VpnService.instance as AndroidVpnService).checkVpnState();

      if (isRunning) {
        print('🔄 Restoring VPN state: connected');

        // ⭐ Load the actual start time from native
        await _loadVpnStartTime();

        setState(() {
          _connectionState = 'connected';
        });

        await _trayService?.updateState(true);
        _fetchUntilIpChanges(_currentIp);
      } else {
        print('🔄 Restoring VPN state: disconnected');
        setState(() => _connectionState = 'disconnected');
      }
    } catch (e) {
      print('Failed to restore VPN state: $e');
    }
  }
}
