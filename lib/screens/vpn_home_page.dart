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
import '../services/settings_service.dart';
import '../services/notification_service.dart';
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

  DateTime? _vpnStartTime;
  Duration _elapsedTime = Duration.zero;
  Timer? _displayTimer;

  Timer? _ipCheckTimer;
  String _currentIp = '';
  String _currentCountry = '';
  String _currentCountryCode = '';
  bool _isLoadingIp = true;
  StreamSubscription<bool>? _vpnSubscription;
  StreamSubscription<VpnEvent>? _eventSubscription;

  bool _isReconnecting = false;
  bool _isAutoReconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  static const int _maxReconnectAttempts = 4;

  bool _isConnecting = false;

  // ✅ FIX 1: Deduplication guard
  int? _lastDeathTimestamp;

  TrayWindowService? _trayService;
  late final VpnService _vpnService = VpnService.instance;

  int get _connectionSeconds => _elapsedTime.inSeconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTrayIfWindows();
    _init();
    _setupVpnEventListener();

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
    _reconnectTimer?.cancel();
    _trayService?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print('📱 App lifecycle changed: $state');

    if (state == AppLifecycleState.resumed) {
      print('📱 App resumed - syncing VPN state and checking for death events');

      // ✅ FIXED: Restore VPN state FIRST, then check for death events
      if (Platform.isAndroid) {
        _restoreVpnState();
      }

      // Check for death events after state is restored
      _checkForStoredDeathEvents();
    }
  }

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

  // ✅ FIX 2: Updated with deduplication
  void _handleVpnEvent(VpnEvent event) {
    if (!mounted) return;

    // ✅ CRITICAL: Deduplicate death events
    if (event.type == VpnEventType.died) {
      if (_lastDeathTimestamp == event.timestamp) {
        print('⚠️ Duplicate death event ignored (timestamp: ${event.timestamp})');
        return;
      }
      _lastDeathTimestamp = event.timestamp;
      print('🔔 NEW death event: ${event.reason} (timestamp: ${event.timestamp})');
    }

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

  // ✅ FIX 3: Add guard to prevent multiple reconnect triggers
  Future<void> _handleVpnDeath(VpnEvent event) async {
    // ✅ Prevent multiple reconnect triggers
    if (_isAutoReconnecting) {
      print('⚠️ Already reconnecting, skipping death handling');
      return;
    }

    final autoReconnectEnabled = await SettingsService.getAutoReconnect();
    final shouldAutoReconnect = autoReconnectEnabled && _isReconnectableReason(event.reason);

    if (shouldAutoReconnect) {
      print('🔄 Auto-reconnect enabled for reason: ${event.reason}');
      await _startAutoReconnect(event);
    } else {
      print('⏸️ Auto-reconnect disabled or not applicable');
      _showAppropriateAlert(event);
    }
  }

  // ✅ FIXED: Don't auto-reconnect if subscription is expired
  bool _isReconnectableReason(String? reason) {
    if (reason == 'permission_revoked') return false;
    if (reason == 'service_killed') return true;
    if (reason == 'process_crashed') return true;
    if (reason == 'vpn_broken') return true;
    if (reason == 'subscription_expired') return false;  // ✅ CHANGED: Don't auto-reconnect!
    return false;
  }

  // ✅ FIX 4 & 5: Better foreground detection + use updated event
  Future<void> _startAutoReconnect(VpnEvent event) async {
    if (_isAutoReconnecting) {
      print('⚠️ Already auto-reconnecting');
      return;
    }

    setState(() {
      _isAutoReconnecting = true;
      _reconnectAttempt = 0;
    });

    // ✅ FIX 4: Cancel notifications early
    if (Platform.isAndroid) {
      await NotificationService.cancelAll();
    }

    print('🔄 Starting auto-reconnect (max $_maxReconnectAttempts attempts)');

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

    final delays = [0, 5, 10, 15];

    for (int i = 0; i < _maxReconnectAttempts; i++) {
      if (!_isAutoReconnecting) break;

      _reconnectAttempt = i + 1;
      print('🔄 Auto-reconnect attempt $_reconnectAttempt/$_maxReconnectAttempts');

      if (delays[i] > 0) {
        print('⏳ Waiting ${delays[i]}s...');
        await Future.delayed(Duration(seconds: delays[i]));
      }

      if (!_isAutoReconnecting) break;

      try {
        if (Platform.isAndroid) {
          await (VpnService.instance as AndroidVpnService).reconnectVpn();
        } else if (Platform.isWindows) {
          await (VpnService.instance as WindowsVpnService).reconnectVpn();
        } else {
          await _vpnService.startVpn();
        }

        print('✅ Auto-reconnect successful on attempt $_reconnectAttempt');

        setState(() {
          _isAutoReconnecting = false;
          _connectionState = 'connected';
          _vpnStartTime = DateTime.now();
        });
        _startDisplayTimer();

        ScaffoldMessenger.of(context).clearSnackBars();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 12),
                  Text('Reconnected automatically!'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        if (Platform.isAndroid) {
          await NotificationService.cancelAll();
        }

        return;

      } catch (e) {
        print('❌ Auto-reconnect attempt $_reconnectAttempt failed: $e');

        if (e.toString().contains('subscription_expired')) {
          print('🔴 Subscription expired - stopping auto-reconnect');

          // ✅ UPDATED: Only update if not already subscription_expired
          if (Platform.isAndroid && event.reason != 'subscription_expired') {
            try {
              await MethodChannel('com.vulcain.vpn/control')
                  .invokeMethod('updateDeathReason', {
                'reason': 'subscription_expired',
                'message': 'Your VPN subscription has expired',
              });
              print('✅ Updated death event to subscription_expired');
            } catch (updateError) {
              print('❌ Failed to update death event: $updateError');
            }
          } else if (event.reason == 'subscription_expired') {
            print('ℹ️ Death reason already subscription_expired, skipping update');
          }

          // ✅ FIX 5: Actually USE the updated event
          event = VpnEvent(
            type: VpnEventType.died,
            reason: 'subscription_expired',
            message: 'Your VPN subscription has expired',
            timestamp: event.timestamp,
          );

          break;
        }

        continue;
      }
    }

    print('🔴 Auto-reconnect FAILED after $_maxReconnectAttempts attempts');
    setState(() => _isAutoReconnecting = false);
    ScaffoldMessenger.of(context).clearSnackBars();

    VpnEvent finalEvent = event;

    if (Platform.isAndroid) {
      try {
        final storedEvent = await MethodChannel('com.vulcain.vpn/control')
            .invokeMethod('checkForDeathEvents');

        if (storedEvent != null && storedEvent['reason'] == 'subscription_expired') {
          finalEvent = VpnEvent(
            type: VpnEventType.died,
            reason: 'subscription_expired',
            message: storedEvent['message'] as String,
            timestamp: storedEvent['timestamp'] as int?,
          );
          print('✅ Using updated death event: subscription_expired');
        }
      } catch (e) {
        print('❌ Failed to check updated death event: $e');
      }
    }

    // ✅ FIX 4: Better foreground detection
    final isForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

    if (!isForeground) {
      if (Platform.isAndroid) {
        await NotificationService.showVpnDisconnectedNotification(
          reason: finalEvent.reason ?? 'unknown',
          message: finalEvent.message,
        );
      }
    }

    if (mounted && isForeground) {
      _showAppropriateAlert(finalEvent);
    }
  }

  void _showAppropriateAlert(VpnEvent event) {
    if (event.reason == 'vpn_broken') {
      _showReconnectDialog(event);
    } else if (event.reason == 'subscription_expired') {
      _showSubscriptionExpiredAlert(event);
    } else {
      _showVpnDiedAlert(event);
    }
  }

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
            child: Text('Not Now', style: TextStyle(color: Colors.grey)),
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

  Future<void> _handleReconnect() async {
    if (!mounted || _isReconnecting) return;

    setState(() => _isReconnecting = true);

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
                Text('Reconnecting...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('Checking subscription...', style: TextStyle(fontSize: 14, color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      print('🔄 Attempting to reconnect...');

      if (Platform.isAndroid) {
        await (VpnService.instance as AndroidVpnService).reconnectVpn();
      } else if (Platform.isWindows) {
        await (VpnService.instance as WindowsVpnService).reconnectVpn();
      } else {
        await _vpnService.startVpn();
      }

      if (mounted) Navigator.pop(context);

      print('✅ Reconnected successfully');

      setState(() {
        _connectionState = 'connected';
        _vpnStartTime = DateTime.now();
      });
      _startDisplayTimer();

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

      if (mounted) Navigator.pop(context);

      final errorString = e.toString();

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
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your VPN subscription has expired. Please renew to continue.',
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
                      style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
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
            child: Text('Close', style: TextStyle(color: Colors.grey)),
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
            label: Text('Renew'),
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
          'Could not reconnect to VPN. Please check your internet connection.',
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _handleReconnect();
            },
            style: ElevatedButton.styleFrom(backgroundColor: MyColors.myOrange),
            child: Text('Try Again'),
          ),
        ],
      ),
    );
  }

  void _showVpnDiedAlert(VpnEvent event) {
    if (!mounted) return;

    String title = 'VPN Disconnected';
    String message = event.message;
    IconData icon = Icons.warning_amber_rounded;
    Color iconColor = Colors.orange;

    if (event.reason == 'service_killed') {
      title = 'VPN Service Stopped';
      message = Platform.isAndroid
          ? 'Android stopped your VPN (low memory). Your connection is no longer protected.'
          : 'The VPN service was stopped by the system.';
      icon = Icons.memory;
      iconColor = Colors.red;
    } else if (event.reason == 'permission_revoked') {
      title = 'Permission Revoked';
      message = 'VPN permission was revoked. Please reconnect.';
      icon = Icons.block;
      iconColor = Colors.red;
    } else if (event.reason == 'process_crashed') {
      title = 'VPN Crashed';
      message = 'The VPN process crashed. Please reconnect.';
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
              child: Text(title, style: TextStyle(color: iconColor, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: TextStyle(fontSize: 16)),
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
                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
            child: Text('Dismiss', style: TextStyle(color: Colors.grey)),
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

  void _showSubscriptionExpiredAlert(VpnEvent event) {
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
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.message, style: TextStyle(fontSize: 16)),
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
                      'VPN disconnected. Your real IP is exposed!',
                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
            child: Text('Dismiss', style: TextStyle(color: Colors.grey)),
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
            label: Text('Renew'),
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

    if (_isConnecting) {
      print('⚠️ Already connecting, ignoring tap');
      return;
    }

    if (_connectionState == 'disconnected') {
      // ✅ Set guard BEFORE async operations
      setState(() {
        _isConnecting = true;
        _connectionState = 'connecting';
      });


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
      } finally {
        // ✅ CRITICAL: Always clear the guard in finally block
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
        }
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
            Text(loc.subscriptionExpiredMessage, style: TextStyle(fontSize: 16)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.cancel, style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              final url = Uri.parse(renewalUrl);
              try {
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
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
        content: Text('You can only have 3 devices connected simultaneously.'),
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
      print('🔄 Checking VPN state on app resume...');

      // ✅ FIXED: Direct network check - bypasses broken SharedPreferences
      final isRunning = await (VpnService.instance as AndroidVpnService).isVpnActive();
      print('🔄 VPN is running: $isRunning');

      if (isRunning) {
        print('🔄 Restoring VPN state: connected');

        final startTimeMs = await (VpnService.instance as AndroidVpnService).getConnectionStartTimeMs();

        if (startTimeMs != null && startTimeMs > 0) {
          final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = startTime;
          });
          print('✅ Restored with start time: $startTime');
        } else {
          setState(() {
            _connectionState = 'connected';
            _vpnStartTime = DateTime.now();
          });
        }

        _startDisplayTimer();
        await _trayService?.updateState(true);
        _fetchUntilIpChanges(_currentIp);
      } else {
        print('🔄 VPN not running');
        setState(() => _connectionState = 'disconnected');
      }
    } catch (e) {
      print('❌ Failed to restore VPN state: $e');
      setState(() => _connectionState = 'disconnected');
    }
  }

  Future<void> _checkForStoredDeathEvents() async {
    if (!Platform.isAndroid) return;

    try {
      print('🔍 Checking for stored death events...');

      final deathEvent = await MethodChannel('com.vulcain.vpn/control')
          .invokeMethod('checkForDeathEvents');

      if (deathEvent != null && deathEvent is Map) {
        print('📨 Found stored death event: ${deathEvent['reason']}');

        // ✅ CRITICAL FIX: Verify VPN is actually dead before processing event
        final isVpnRunning = await (VpnService.instance as AndroidVpnService).checkVpnState();

        if (isVpnRunning) {
          print('✅ VPN is running - ignoring stale death event and clearing it');

          // Clear the stale death event
          await MethodChannel('com.vulcain.vpn/control')
              .invokeMethod('clearDeathEvents');

          return; // Don't process the stale event
        }

        print('💀 VPN is NOT running - processing death event');

        final event = VpnEvent(
          type: VpnEventType.died,
          reason: deathEvent['reason'] as String?,
          message: deathEvent['message'] as String,
          timestamp: deathEvent['timestamp'] as int?,
        );

        _handleVpnEvent(event);
      } else {
        print('✅ No stored death events');
      }
    } catch (e) {
      print('❌ Error checking death events: $e');
    }
  }
}
