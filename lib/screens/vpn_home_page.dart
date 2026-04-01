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
import 'package:url_launcher/url_launcher.dart';

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

    // ⭐ CRITICAL: Calculate elapsed time IMMEDIATELY (don't wait for first tick)
    if (_vpnStartTime != null && mounted) {
      setState(() {
        _elapsedTime = DateTime.now().difference(_vpnStartTime!);
      });
    }

    // Then start periodic updates
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
    final loc = AppLocalizations.of(context)!;

    try {
      final result = await Process.run('net', ['session'], runInShell: true);
      if (result.exitCode != 0 && mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(loc.adminRequiredTitle),
            content: Text(loc.adminRequiredMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(loc.ok),
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
    final loc = AppLocalizations.of(context)!;

    if (_connectionState == 'disconnected') {
      setState(() => _connectionState = 'connecting');

      final ipBeforeConnect = _currentIp;

      try {
        final success = await _vpnService.startVpn();
        if (success) {
          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = DateTime.now();
          });
          _startDisplayTimer();
          _fetchUntilIpChanges(ipBeforeConnect);
        } else {
          setState(() => _connectionState = 'disconnected');
          _showGenericError(loc);
        }
      } catch (e) {
        setState(() => _connectionState = 'disconnected');

        if (!mounted) return;

        final errorString = e.toString();

        // 🐛 DEBUG: Print the actual error to console
        print('❌ VPN Connection Error: $errorString');
        if (e is PlatformException) {
          print('   Code: ${e.code}');
          print('   Message: ${e.message}');
          print('   Details: ${e.details}');
        }

        // ✅ PRIORITY 1: Check subscription status (403 Forbidden)
        if (errorString.contains('No active subscription') ||
            errorString.contains('Subscription expired') ||
            errorString.contains('403')) {
          _showSubscriptionExpiredDialog(loc, errorString);
          return;
        }

        // ✅ PRIORITY 2: Check device registration (401 Unauthorized ONLY)
        if (errorString.contains('Device not registered') ||
            errorString.contains('401') ||
            errorString.contains('Unauthorized')) {
          _showNotRegisteredDialog(loc);
          return;
        }

        // ✅ PRIORITY 3: Check device limits (429 Too Many Requests)
        if (errorString.contains('Maximum active devices reached') ||
            errorString.contains('429')) {
          _showDeviceLimitDialog(loc);
          return;
        }

        // ✅ PRIORITY 4: Android permissions (specific codes)
        if (Platform.isAndroid && e is PlatformException) {
          if (e.code == 'NOTIFICATION_PERMISSION_DENIED') {
            _showPermissionDialog(loc, loc.notificationPermissionMessage);
            return;
          }
          if (e.code == 'VPN_PERMISSION_DENIED') {
            _showPermissionDialog(loc, loc.vpnPermissionMessage);
            return;
          }
        }

        // ✅ PRIORITY 5: Generic error
        _showGenericError(loc, errorString);
      }
    }
    else if (_connectionState == 'connected') {
      setState(() => _connectionState = 'disconnecting');

      await _vpnService.stopVpn();
      _stopDisplayTimer();

      setState(() {
        _connectionState = 'disconnected';
      });

      _fetchCurrentIpAndLocationWithRetry();
    }
  }

  // ✅ UPDATED: Extract renewal URL from error string
  void _showSubscriptionExpiredDialog(AppLocalizations loc, String errorString) {
    // Try to extract renewal URL from error (format: "error|renewal_url:https://...")
    String renewalUrl = 'https://www.vulcainvpn.com/dashboard';
    if (errorString.contains('renewal_url:')) {
      try {
        final urlPart = errorString.split('renewal_url:')[1];
        renewalUrl = urlPart.split('|')[0].trim();
      } catch (_) {
        // Use default URL if parsing fails
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.card_membership, color: MyColors.myOrange),
            SizedBox(width: 8),
            Expanded(child: Text(loc.subscriptionRequiredTitle)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.subscriptionExpiredMessage,
              style: TextStyle(fontSize: 16),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              loc.cancel,
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              final url = Uri.parse(renewalUrl);
              try {
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } else {
                  throw 'Could not launch URL';
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please visit $renewalUrl to renew'),
                      backgroundColor: MyColors.myOrange,
                      duration: Duration(seconds: 5),
                    ),
                  );
                }
              }
            },
            icon: Icon(Icons.shopping_cart),
            label: Text(loc.renewNow),
            style: ElevatedButton.styleFrom(
              backgroundColor: MyColors.myOrange,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ✅ Device not registered dialog
  void _showNotRegisteredDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.notRegisteredTitle),
        content: Text(loc.notRegisteredMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.ok),
          ),
        ],
      ),
    );
  }

  // ✅ Device limit dialog
  void _showDeviceLimitDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.deviceLimitTitle),
        content: Text('You can only have 3 devices connected simultaneously. Please disconnect another device first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.ok),
          ),
        ],
      ),
    );
  }

  // ✅ Permission dialog
  void _showPermissionDialog(AppLocalizations loc, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.permissionRequiredTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.ok),
          ),
        ],
      ),
    );
  }

  // ✅ Generic error dialog
  void _showGenericError(AppLocalizations loc, [String? errorString]) {
    final message = errorString != null
        ? '${loc.connectionFailedMessage}\n\nError: ${errorString.replaceAll('Exception: ', '').split('|')[0]}'  // Strip metadata
        : loc.connectionFailedMessage;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.connectionErrorTitle),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.ok),
          ),
        ],
      ),
    );
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
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.home_outlined),
            activeIcon: const Icon(Icons.home),
            label: loc.navHome,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.card_membership_outlined),
            activeIcon: const Icon(Icons.card_membership),
            label: loc.navSubscription,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.settings_outlined),
            activeIcon: const Icon(Icons.settings),
            label: loc.navSettings,
          ),
        ],
      ),
    );
  }

  // ⭐ UPDATED: Restore VPN state and load start time with fallback
  Future<void> _restoreVpnState() async {
    if (!Platform.isAndroid) return;

    try {
      print('🔄 Checking VPN state...');
      final isRunning = await (VpnService.instance as AndroidVpnService).checkVpnState();
      print('🔄 VPN is running: $isRunning');

      if (isRunning) {
        print('🔄 Restoring VPN state: connected');

        // ⭐ Try to load the actual start time from native
        print('🔄 Loading start time from native...');
        final startTimeMs = await (VpnService.instance as AndroidVpnService).getConnectionStartTimeMs();
        print('🔄 Start time from native: $startTimeMs');

        if (startTimeMs != null && startTimeMs > 0) {
          // ✅ Use stored start time
          final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
          final elapsed = DateTime.now().difference(startTime);

          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = startTime;
          });

          print('✅ Loaded start time: $startTime');
          print('✅ Elapsed time: ${elapsed.inHours}h ${elapsed.inMinutes % 60}m ${elapsed.inSeconds % 60}s');

          // Start the display timer (this will calculate elapsed time immediately)
          _startDisplayTimer();
        } else {
          // ⚠️ Fallback: Use current time if we can't load stored time
          print('⚠️ No stored start time found, using current time as fallback');
          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = DateTime.now();
          });
          _startDisplayTimer();
        }

        await _trayService?.updateState(true);
        _fetchUntilIpChanges(_currentIp);
      } else {
        print('🔄 Restoring VPN state: disconnected');
        setState(() => _connectionState = 'disconnected');
      }
    } catch (e) {
      print('❌ Failed to restore VPN state: $e');
    }
  }
}
