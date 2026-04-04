import 'package:flutter/material.dart';
import 'dart:io';
import '../../colors.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/vpn_service_android.dart';
import '../../services/vpn_service_windows.dart';
import '../../widgets/info_card.dart';
import '../../widgets/info_row.dart';
import '../../l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

class SubscriptionTab extends StatefulWidget {
  const SubscriptionTab({super.key});

  @override
  State<SubscriptionTab> createState() => _SubscriptionTabState();
}

class _SubscriptionTabState extends State<SubscriptionTab>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _subscriptionData;
  bool _isLoading = true;
  String? _error;

  // ✅ FIX: Don't cache this tab - always refresh
  @override
  bool get wantKeepAlive => false;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  // ✅ FIX: Refresh subscription whenever tab becomes visible
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (mounted) {
      _loadSubscription();
    }
  }

  // ✅ FIX: Console logging only (no Windows file writing to prevent hangs)
  Future<void> _log(String message) async {
    print(message);
  }

  Future<void> _loadSubscription() async {
    // Prevent multiple simultaneous loads
    if (_isLoading && _subscriptionData != null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _log('📊 Loading subscription...');

      // Check if we have tokens
      final token = await AuthService.getValidAccessToken();
      await _log('   Token available: ${token != null}');
      if (token != null) {
        await _log('   Token length: ${token.length}');
      } else {
        await _log('   ❌ No token found!');
      }

      // Try to fetch subscription
      await _log('   Calling API...');
      final data = await ApiService.fetchSubscription();
      await _log('   ✅ Subscription data received');
      await _log('   Data keys: ${data.keys.toList()}');

      // ✅ Check if widget is still mounted before calling setState
      if (!mounted) return;

      setState(() {
        _subscriptionData = data;
        _isLoading = false;
      });

      // ✅ NEW: Check if subscription is expired and handle it
      await _checkAndHandleExpiredSubscription();

    } catch (e, stackTrace) {
      await _log('❌ Subscription load error: $e');
      await _log('   Stack: ${stackTrace.toString().split('\n').take(5).join(' | ')}');

      // ✅ Check mounted before accessing context or calling setState
      if (!mounted) return;

      final loc = AppLocalizations.of(context)!;
      setState(() {
        _error = loc.failedLoadSubscription;
        _isLoading = false;
      });
    }
  }

  // ✅ NEW: Check if subscription is expired and disconnect VPN
  Future<void> _checkAndHandleExpiredSubscription() async {
    if (_subscriptionData == null) return;

    final sub = _subscriptionData?['subscription'];
    if (sub == null) return;

    final status = sub['status'] as String?;
    final expiresAt = DateTime.tryParse(sub['expires_at'] ?? '');

    // Check if subscription is expired
    final isExpired = status != 'active' ||
                     (expiresAt != null && expiresAt.isBefore(DateTime.now()));

    if (isExpired) {
      await _log('⚠️ Subscription is EXPIRED! Disconnecting VPN...');
      await _disconnectVpnAndAlert();
    }
  }

  // ✅ NEW: Disconnect VPN and show alert
  Future<void> _disconnectVpnAndAlert() async {
    try {
      // Disconnect VPN based on platform
      if (Platform.isAndroid) {
        await AndroidVpnService().stopVpn();
        await _log('✅ Android VPN disconnected');
      } else if (Platform.isWindows) {
        await WindowsVpnService().stopVpn();
        await _log('✅ Windows VPN disconnected');
      }

      // Show alert to user
      if (!mounted) return;

      final loc = AppLocalizations.of(context)!;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
              SizedBox(width: 12),
              Text(
                'Subscription Expired', // ✅ Hardcoded for now
                style: TextStyle(color: Colors.red),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your subscription has expired and VPN has been disconnected for your security.',
                style: TextStyle(fontSize: 15),
              ),
              SizedBox(height: 12),
              Text(
                'Please renew your subscription to continue using VulcainVPN.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('OK'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _openRenewalPage();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: MyColors.myOrange,
              ),
              child: Text(
                'Renew Now',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      await _log('❌ Failed to disconnect VPN: $e');
    }
  }

  // ✅ NEW: Open renewal page
  Future<void> _openRenewalPage() async {
    final url = Uri.parse('https://www.vulcainvpn.com/dashboard');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        await _log('❌ Could not launch URL: $url');
      }
    } catch (e) {
      await _log('❌ Error launching URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final loc = AppLocalizations.of(context)!;

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
              child: Text(loc.retry,
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    final sub = _subscriptionData?['subscription'];
    if (sub == null) {
      return Center(child: Text(loc.noSubscriptionData));
    }

    final plan = sub['plan'] ?? {};
    final server = sub['server'] ?? {};
    final devices = sub['devices'] ?? {};
    final expiresAt = DateTime.tryParse(sub['expires_at'] ?? '');
    final daysRemaining =
        expiresAt != null ? expiresAt.difference(DateTime.now()).inDays : 0;
    final activeDevices = devices['active'] ?? 0;
    final maxDevices = devices['max'] ?? 3;

    // ✅ NEW: Check if subscription is expired (for UI display)
    final status = sub['status'] as String?;
    final isExpired = status != 'active' ||
                     (expiresAt != null && expiresAt.isBefore(DateTime.now()));

    return RefreshIndicator(
      onRefresh: _loadSubscription,
      color: MyColors.myOrange,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ✅ NEW: Show warning banner if expired
          if (isExpired)
            Container(
              margin: EdgeInsets.only(bottom: 16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red[50],
                border: Border.all(color: Colors.red, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Subscription Expired', // ✅ Hardcoded
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Please renew to continue using VulcainVPN', // ✅ Hardcoded
                          style: TextStyle(
                            color: Colors.red[700],
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          InfoCard(
            title: loc.subscription,
            icon: Icons.card_membership,
            children: [
              InfoRow(
                label: loc.plan,
                value: '${plan['name'] ?? '-'}',
              ),
              InfoRow(
                label: loc.reference,
                value: sub['name'] ?? '-',
              ),
              InfoRow(
                label: loc.status,
                value: sub['status'] ?? '-',
                valueColor:
                    sub['status'] == 'active' ? Colors.green : Colors.red,
              ),
              InfoRow(
                label: loc.expires,
                value: expiresAt != null
                    ? '${expiresAt.day}/${expiresAt.month}/${expiresAt.year}'
                    : '-',
              ),
              InfoRow(
                label: loc.daysRemaining,
                value: '$daysRemaining ${loc.daysSuffix}',
                valueColor: daysRemaining < 7 ? Colors.red : Colors.green,
              ),
            ],
          ),
          const SizedBox(height: 16),
          InfoCard(
            title: loc.devices,
            icon: Icons.devices_outlined,
            children: [
              InfoRow(
                label: loc.activeConnections,
                value: '$activeDevices / $maxDevices',
                valueColor:
                    activeDevices >= maxDevices ? Colors.red : Colors.green,
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

          // ✅ NEW: Renew button if expired
          if (isExpired) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _openRenewalPage,
                icon: Icon(Icons.refresh, color: Colors.white),
                label: Text(
                  'Renew Now', // ✅ Hardcoded
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MyColors.myOrange,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
