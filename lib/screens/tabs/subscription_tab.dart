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

  @override
  bool get wantKeepAlive => false;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (mounted) {
      _loadSubscription();
    }
  }

  Future<void> _loadSubscription() async {
    if (_isLoading && _subscriptionData != null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      print('📊 Loading subscription...');

      final token = await AuthService.getValidAccessToken();
      print('   Token available: ${token != null}');

      final data = await ApiService.fetchSubscription();
      print('   ✅ Subscription data received');

      if (!mounted) return;

      setState(() {
        _subscriptionData = data;
        _isLoading = false;
      });

      // ✅ UPDATED: Just disconnect VPN if expired (no popup)
      await _checkAndDisconnectIfExpired();

    } catch (e, stackTrace) {
      print('❌ Subscription load error: $e');
      print('   Stack: ${stackTrace.toString().split('\n').take(5).join(' | ')}');

      if (!mounted) return;

      final loc = AppLocalizations.of(context)!;
      setState(() {
        _error = loc.failedLoadSubscription;
        _isLoading = false;
      });
    }
  }

  // ✅ UPDATED: Silently disconnect VPN if expired (no popup)
  Future<void> _checkAndDisconnectIfExpired() async {
    if (_subscriptionData == null) return;

    final sub = _subscriptionData?['subscription'];
    if (sub == null) return;

    final status = sub['status'] as String?;
    final expiresAt = DateTime.tryParse(sub['expires_at'] ?? '');

    // Check if subscription is expired
    final isExpired = status != 'active' ||
                     (expiresAt != null && expiresAt.isBefore(DateTime.now()));

    if (isExpired) {
      print('⚠️ Subscription is EXPIRED! Disconnecting VPN silently...');
      await _disconnectVpn();
    }
  }

  // ✅ UPDATED: Just disconnect VPN (no popup, no alert)
  Future<void> _disconnectVpn() async {
    try {
      if (Platform.isAndroid) {
        await AndroidVpnService().stopVpn();
        print('✅ Android VPN disconnected (expired subscription)');
      } else if (Platform.isWindows) {
        await WindowsVpnService().stopVpn();
        print('✅ Windows VPN disconnected (expired subscription)');
      }
    } catch (e) {
      print('❌ Failed to disconnect VPN: $e');
    }
  }

  // ✅ Open renewal page
  Future<void> _openRenewalPage() async {
    final url = Uri.parse('https://www.vulcainvpn.com/dashboard');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        print('❌ Could not launch URL: $url');
      }
    } catch (e) {
      print('❌ Error launching URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

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

    // Check if subscription is expired
    final status = sub['status'] as String?;
    final isExpired = status != 'active' ||
                     (expiresAt != null && expiresAt.isBefore(DateTime.now()));

    return RefreshIndicator(
      onRefresh: _loadSubscription,
      color: MyColors.myOrange,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ✅ Red warning banner if expired
          if (isExpired)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red[50],
                border: Border.all(color: Colors.red, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Subscription Expired',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Please renew to continue using VulcainVPN',
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

          // ✅ Renew button if expired
          if (isExpired) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _openRenewalPage,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text(
                  'Renew Now',
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
