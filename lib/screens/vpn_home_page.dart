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
import '../services/vpn_service_windows.dart';
import '../services/settings_service.dart'; // ✅ NEW
import '../services/notification_service.dart'; // ✅ NEW
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

class _VpnHomePageState extends State<VpnHomePage> with WidgetsBindingObserver {
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

  // ✅ PRIORITY 1: Add event subscription
  StreamSubscription<VpnEvent>? _eventSubscription;

  // ✅ PRIORITY 3: Add reconnecting flag
  bool _isReconnecting = false;

  // ✅ NEW: Auto-reconnect state
  bool _isAutoReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  static const int _maxReconnectAttempts = 4; // ~30 seconds total

  TrayWindowService? _trayService;

  late final VpnService _vpnService = VpnService.instance;

  // ⭐ CHANGED: Computed property instead of _connectionSeconds
  int get _connectionSeconds => _elapsedTime.inSeconds;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initTrayIfWindows();
    _init();

    // ✅ PRIORITY 1: Setup event listener
    _setupVpnEventListener();

    // ✅ NEW: Check for death events on startup
    Future.delayed(Duration(milliseconds: 800), () {
      _checkForStoredDeathEvents();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _displayTimer?.cancel();
    _ipCheckTimer?.cancel();
    _vpnSubscription?.cancel();
    _eventSubscription?.cancel();
    _reconnectTimer?.cancel(); // ✅ NEW
    _trayService?.dispose();
    super.dispose();
  }

  // ✅ NEW: Called when app lifecycle changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    print('📱 App lifecycle changed: $state');

    // When app comes back to foreground, check for stored death events
    if (state == AppLifecycleState.resumed) {
      print('📱 App resumed from background - checking for death events');
      _checkForStoredDeathEvents();
    }
  }

  // ✅ PRIORITY 1: Setup VPN event listener
  void _setupVpnEventListener() {
    if (Platform.isAndroid) {
      _eventSubscription = AndroidVpnService.eventStream.listen((event) {
        print('📡 Flutter received VPN event: $event');
        _handleVpnEvent(event);
      });
    } else if (Platform.isWindows) {
      _eventSubscription = WindowsVpnService.eventStream.listen((event) {
        print('📡 Flutter received VPN event: $event');
        _handleVpnEvent(event);
      });
    }
  }

  // ✅ UPDATED: Handle VPN events with auto-reconnect
  void _handleVpnEvent(VpnEvent event) {
    if (!mounted) return;

    print('🔔 Handling event: ${event.type}, reason: ${event.reason}');

    switch (event.type) {
      case VpnEventType.died:
        print('💀 VPN DIED: ${event.reason} - ${event.message}');

        setState(() {
          _connectionState = 'disconnected';
          _stopDisplayTimer();
        });

        _trayService?.updateState(false);
        _fetchCurrentIpAndLocationWithRetry();

        // ✅ NEW: Check if we should auto-reconnect
        _handleVpnDeath(event);
        break;

      case VpnEventType.connected:
        print('✅ VPN connected event');
        break;

      case VpnEventType.disconnected:
        print('🔴 VPN disconnected event');
        setState(() {
          _connectionState = 'disconnected';
          _stopDisplayTimer();
        });
        break;

      case VpnEventType.error:
        print('❌ VPN error event: ${event.message}');
        _showErrorSnackbar(event.message);
        break;
    }
  }

  // ✅ NEW: Handle VPN death with auto-reconnect logic
  Future<void> _handleVpnDeath(VpnEvent event) async {
    // Check if auto-reconnect is enabled
    final autoReconnectEnabled = await SettingsService.getAutoReconnect();

    // Determine if this reason is reconnectable
    final shouldAutoReconnect = autoReconnectEnabled &&
      _isReconnectableReason(event.reason);

    if (shouldAutoReconnect) {
      print('🔄 Auto-reconnect enabled for reason: ${event.reason}');
      await _startAutoReconnect(event);
    } else {
      print('⏸️ Auto-reconnect disabled or not applicable');
      // Show alert immediately
      _showAppropriateAlert(event);
    }
  }

  // ✅ NEW: Check if reason is reconnectable
  bool _isReconnectableReason(String? reason) {
    // Don't auto-reconnect for these reasons:
    if (reason == 'permission_revoked') return false; // User action

    // DO auto-reconnect for these:
    if (reason == 'service_killed') return true;      // Android killed it
    if (reason == 'process_crashed') return true;     // Windows crash
    if (reason == 'vpn_broken') return true;          // Server down or expired
    if (reason == 'subscription_expired') return true; // Will fail, but worth trying

    return false; // Unknown reasons: don't auto-reconnect
  }

  // ✅ NEW: Start auto-reconnect attempts
  Future<void> _startAutoReconnect(VpnEvent event) async {
    if (_isAutoReconnecting) {
      print('⚠️ Already auto-reconnecting, skipping');
      return;
    }

    setState(() {
      _isAutoReconnecting = true;
      _reconnectAttempt = 0;
    });

    print('🔄 Starting auto-reconnect (max $_maxReconnectAttempts attempts)');

    // Show subtle indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text('Auto-reconnecting...'),
            ],
          ),
          duration: Duration(seconds: 30),
          backgroundColor: MyColors.myOrange,
        ),
      );
    }

    // Try reconnecting with exponential backoff
    final delays = [0, 5, 10, 15]; // seconds: 0s, 5s, 10s, 15s = ~30s total

    for (int i = 0; i < _maxReconnectAttempts; i++) {
      if (!_isAutoReconnecting) break; // User manually stopped

      _reconnectAttempt = i + 1;
      print('🔄 Auto-reconnect attempt $_reconnectAttempt/$_maxReconnectAttempts');

      // Wait before attempt (except first one)
      if (delays[i] > 0) {
        print('⏳ Waiting ${delays[i]}s before retry...');
        await Future.delayed(Duration(seconds: delays[i]));
      }

      if (!_isAutoReconnecting) break;

      try {
        // Attempt reconnect (with subscription check)
        if (Platform.isAndroid) {
          await (VpnService.instance as AndroidVpnService).reconnectVpn();
        } else if (Platform.isWindows) {
          await (VpnService.instance as WindowsVpnService).reconnectVpn();
        } else {
          await _vpnService.startVpn();
        }

        // ✅ SUCCESS!
        print('✅ Auto-reconnect successful on attempt $_reconnectAttempt');

        setState(() {
          _isAutoReconnecting = false;
          _connectionState = 'connected';
          _vpnStartTime = DateTime.now();
        });
        _startDisplayTimer();

        // Close any existing snackbar
        ScaffoldMessenger.of(context).clearSnackBars();

        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 12),
                  Text('✅ Reconnected automatically!'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        // Cancel notification if it was shown
        if (Platform.isAndroid) {
          await NotificationService.cancelAll();
        }

        return; // Success - exit

      } catch (e) {
        print('❌ Auto-reconnect attempt $_reconnectAttempt failed: $e');

        // Check if subscription expired
        if (e.toString().contains('subscription_expired')) {
          print('🔴 Subscription expired - stopping auto-reconnect');
          break; // Don't retry if subscription expired
        }

        // Continue to next attempt
        continue;
      }
    }

    // ❌ All attempts failed
    print('🔴 Auto-reconnect FAILED after $_maxReconnectAttempts attempts');

    setState(() => _isAutoReconnecting = false);

    // Close reconnecting snackbar
    ScaffoldMessenger.of(context).clearSnackBars();

    // Show notification if app is backgrounded
    if (!mounted || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      if (Platform.isAndroid) {
        await NotificationService.showVpnDisconnectedNotification(
          reason: event.reason ?? 'unknown',
          message: event.message,
        );
      }
    }

    // Show alert if app is in foreground
    if (mounted) {
      _showAppropriateAlert(event);
    }
  }

  // ✅ NEW: Show appropriate alert based on event
  void _showAppropriateAlert(VpnEvent event) {
    if (event.reason == 'vpn_broken') {
      _showReconnectDialog(event);
    } else if (event.reason == 'subscription_expired') {
      _showSubscriptionExpiredAlert(event);
    } else {
      _showVpnDiedAlert(event);
    }
  }

  // ✅ PRIORITY 3: Show reconnect dialog
  void _showReconnectDialog(VpnEvent event) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'VPN Connection Lost',
                style: TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The VPN connection has been lost. Would you like to reconnect?',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your real IP may be exposed!',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Not Now',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              await _handleReconnect();
            },
            icon: Icon(Icons.vpn_lock),
            label: Text('Reconnect'),
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

  // ✅ PRIORITY 3: Handle reconnect with subscription check
  Future<void> _handleReconnect() async {
    if (!mounted || _isReconnecting) return;

    setState(() => _isReconnecting = true);

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text(
                  'Reconnecting...',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  'Checking subscription...',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      print('🔄 Attempting to reconnect with subscription check...');

      if (Platform.isAndroid) {
        await (VpnService.instance as AndroidVpnService).reconnectVpn();
      } else if (Platform.isWindows) {
        await (VpnService.instance as WindowsVpnService).reconnectVpn();
      } else {
        await _vpnService.startVpn();
      }

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      // Success!
      print('✅ Reconnected successfully');

      setState(() {
        _connectionState = 'connected';
        _vpnStartTime = DateTime.now();
      });
      _startDisplayTimer();

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('✅ Reconnected successfully!'),
              ],
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }

    } catch (e) {
      print('❌ Reconnect failed: $e');

      // Close loading dialog
      if (mounted) Navigator.pop(context);

      final errorString = e.toString();

      // ✅ PRIORITY 3: Check if subscription expired
      if (errorString.contains('subscription_expired')) {
        _showSubscriptionExpiredAfterReconnect();
      } else {
        _showReconnectFailedAlert(errorString);
      }
    } finally {
      if (mounted) {
        setState(() => _isReconnecting = false);
      }
    }
  }

  // ✅ PRIORITY 3: Show subscription expired alert after failed reconnect
  void _showSubscriptionExpiredAfterReconnect() {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.card_membership, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Subscription Expired',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your VPN subscription has expired. Please renew your subscription to continue using the VPN.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your connection is currently unprotected',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              final url = Uri.parse('https://www.vulcainvpn.com/dashboard');
              try {
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please visit vulcainvpn.com to renew'),
                      backgroundColor: MyColors.myOrange,
                    ),
                  );
                }
              }
            },
            icon: Icon(Icons.shopping_cart),
            label: Text('Renew Subscription'),
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

  // ✅ PRIORITY 3: Show generic reconnect failed alert
  void _showReconnectFailedAlert(String errorString) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Text('Reconnect Failed'),
          ],
        ),
        content: Text(
          'Could not reconnect to VPN. Please check your internet connection and try again later.',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK', style: TextStyle(fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _handleReconnect(); // Try again
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: MyColors.myOrange,
            ),
            child: Text('Try Again'),
          ),
        ],
      ),
    );
  }

  // ✅ PRIORITY 1: Show VPN died alert
  void _showVpnDiedAlert(VpnEvent event) {
    if (!mounted) return;

    final loc = AppLocalizations.of(context)!;

    String title = 'VPN Disconnected';
    String message = event.message;
    IconData icon = Icons.warning_amber_rounded;
    Color iconColor = Colors.orange;

    // Customize based on reason
    if (event.reason == 'service_killed') {
      title = 'VPN Service Stopped';
      message = Platform.isAndroid
          ? 'Android stopped your VPN (low memory or system cleanup). Your connection is no longer protected.'
          : 'The VPN service was stopped by the system.';
      icon = Icons.memory;
      iconColor = Colors.red;
    } else if (event.reason == 'permission_revoked') {
      title = 'Permission Revoked';
      message = 'VPN permission was revoked. Please reconnect to restore protection.';
      icon = Icons.block;
      iconColor = Colors.red;
    } else if (event.reason == 'process_crashed') {
      title = 'VPN Crashed';
      message = 'The VPN process crashed unexpectedly. Please reconnect.';
      icon = Icons.error_outline;
      iconColor = Colors.red;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: iconColor, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: iconColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your real IP may be exposed!',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Dismiss',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _toggleConnection();
            },
            icon: Icon(Icons.vpn_lock),
            label: Text('Reconnect'),
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

  // ✅ PRIORITY 1: Show error snackbar
  void _showErrorSnackbar(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white),
            SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  void _startDisplayTimer() {
    _displayTimer?.cancel();

    if (_vpnStartTime != null && mounted) {
      setState(() {
        _elapsedTime = DateTime.now().difference(_vpnStartTime!);
      });
    }

    _displayTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_vpnStartTime != null && mounted) {
        setState(() {
          _elapsedTime = DateTime.now().difference(_vpnStartTime!);
        });
      }
    });
  }

  void _stopDisplayTimer() {
    _displayTimer?.cancel();
    _vpnStartTime = null;
    _elapsedTime = Duration.zero;
  }

  void _showSubscriptionExpiredAlert(VpnEvent event) {
    if (!mounted) return;

    final loc = AppLocalizations.of(context)!;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.card_membership, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Subscription Expired',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.message,
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'VPN has been disconnected. Your real IP is now exposed!',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Dismiss',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              final url = Uri.parse('https://www.vulcainvpn.com/dashboard');
              try {
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please visit vulcainvpn.com to renew'),
                      backgroundColor: MyColors.myOrange,
                    ),
                  );
                }
              }
            },
            icon: Icon(Icons.shopping_cart),
            label: Text('Renew Subscription'),
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

        print('❌ VPN Connection Error: $errorString');
        if (e is PlatformException) {
          print('   Code: ${e.code}');
          print('   Message: ${e.message}');
          print('   Details: ${e.details}');
        }

        if (errorString.contains('No active subscription') ||
            errorString.contains('Subscription expired') ||
            errorString.contains('403')) {
          _showSubscriptionExpiredDialog(loc, errorString);
          return;
        }

        if (errorString.contains('Device not registered') ||
            errorString.contains('401') ||
            errorString.contains('Unauthorized')) {
          _showNotRegisteredDialog(loc);
          return;
        }

        if (errorString.contains('Maximum active devices reached') ||
            errorString.contains('429')) {
          _showDeviceLimitDialog(loc);
          return;
        }

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

  void _showSubscriptionExpiredDialog(AppLocalizations loc, String errorString) {
    String renewalUrl = 'https://www.vulcainvpn.com/dashboard';
    if (errorString.contains('renewal_url:')) {
      try {
        final urlPart = errorString.split('renewal_url:')[1];
        renewalUrl = urlPart.split('|')[0].trim();
      } catch (_) {}
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

  void _showGenericError(AppLocalizations loc, [String? errorString]) {
    final message = errorString != null
        ? '${loc.connectionFailedMessage}\n\nError: ${errorString.replaceAll('Exception: ', '').split('|')[0]}'
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

  Future<void> _restoreVpnState() async {
    if (!Platform.isAndroid) return;

    try {
      print('🔄 Checking VPN state...');
      final isRunning = await (VpnService.instance as AndroidVpnService).checkVpnState();
      print('🔄 VPN is running: $isRunning');

      if (isRunning) {
        print('🔄 Restoring VPN state: connected');

        print('🔄 Loading start time from native...');
        final startTimeMs = await (VpnService.instance as AndroidVpnService).getConnectionStartTimeMs();
        print('🔄 Start time from native: $startTimeMs');

        if (startTimeMs != null && startTimeMs > 0) {
          final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
          final elapsed = DateTime.now().difference(startTime);

          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = startTime;
          });

          print('✅ Loaded start time: $startTime');
          print('✅ Elapsed time: ${elapsed.inHours}h ${elapsed.inMinutes % 60}m ${elapsed.inSeconds % 60}s');

          _startDisplayTimer();
        } else {
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

  Future<void> _checkForStoredDeathEvents() async {
    if (!Platform.isAndroid) return;

    try {
      print('🔍 Calling checkForDeathEvents method...');

      final deathEvent = await MethodChannel('com.vulcain.vpn/control')
          .invokeMethod('checkForDeathEvents');

      print('🔍 Result from checkForDeathEvents: $deathEvent');

      if (deathEvent != null && deathEvent is Map) {
        print('📨 Found stored death event: ${deathEvent['reason']}');

        final event = VpnEvent(
          type: VpnEventType.died,
          reason: deathEvent['reason'] as String?,
          message: deathEvent['message'] as String,
          timestamp: deathEvent['timestamp'] as int?,
        );

        _handleVpnEvent(event);
      } else {
        print('✅ No stored death events found');
      }
    } catch (e) {
      print('❌ Error checking for death events: $e');
    }
  }
}
