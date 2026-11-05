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
import '../paywall_screen.dart';

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
  bool _noSubscription = false; // Signed in but never subscribed (API 404)

  // Tracks when we last successfully loaded, to avoid re-fetching on every
  // rebuild triggered by locale/theme changes via didChangeDependencies.
  DateTime? _lastLoadedAt;
  static const _reloadCooldown = Duration(minutes: 5);

  @override
  bool get wantKeepAlive => false; // Tab rebuilds when revisited — intentional

  // ✅ No initState: do NOT call _loadSubscription() there.
  // Flutter always calls didChangeDependencies() immediately after initState
  // on first build, which handles the initial load. Calling it there too
  // caused two simultaneous API requests every time the tab opened.

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Fires on first build (handles initial load) and on subsequent tab visits.
    // Cooldown prevents unnecessary re-fetches on locale/theme rebuilds.
    if (!mounted) return;
    final shouldReload = _lastLoadedAt == null ||
        DateTime.now().difference(_lastLoadedAt!) > _reloadCooldown;
    if (shouldReload) {
      _loadSubscription(force: true);
    }
  }

  Future<void> _loadSubscription({bool force = false}) async {
    // Fixed guard: skip if we're NOT loading and already have data.
    // (Original was inverted: `_isLoading && data != null` almost never fires)
    // force=true bypasses this for manual pull-to-refresh and retry button.
    if (!force && !_isLoading && _subscriptionData != null) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _noSubscription = false;
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

      _lastLoadedAt = DateTime.now();

      // ✅ UPDATED: Just disconnect VPN if expired (no popup)
      await _checkAndDisconnectIfExpired();

    } catch (e, stackTrace) {
      print('❌ Subscription load error: $e');
      print('   Stack: ${stackTrace.toString().split('\n').take(5).join(' | ')}');

      if (!mounted) return;

      // 404 = no subscription yet: not an error, show the subscribe screen
      if (e.toString().contains('404')) {
        setState(() {
          _subscriptionData = null;
          _noSubscription = true;
          _isLoading = false;
        });
        return;
      }

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

  // Android: Google Play subscription screen. Windows/macOS: website.
  Future<void> _openRenewalPage() async {
    if (Platform.isAndroid) {
      final subscribed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const PaywallScreen()),
      );
      if (subscribed == true) await _loadSubscription(force: true);
      return;
    }

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

  // Google Play's own subscription page (cancel, change payment method)
  Future<void> _openPlaySubscriptions() async {
    final url = Uri.parse(
        'https://play.google.com/store/account/subscriptions?sku=vulcain_premium&package=com.vulcainvpn.app');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      print('❌ Could not open Google Play subscriptions: $e');
    }
  }

  Widget _primaryButton(String label, IconData icon, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white),
        label: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: MyColors.myOrange,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
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
              onPressed: () => _loadSubscription(force: true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: MyColors.myOrange),
              child: Text(loc.retry,
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }

    if (_noSubscription) {
      return RefreshIndicator(
        onRefresh: () => _loadSubscription(force: true),
        color: MyColors.myOrange,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),
            const Icon(Icons.card_membership, size: 64, color: MyColors.myOrange),
            const SizedBox(height: 16),
            const Text(
              'No active subscription',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isAndroid
                  ? 'Subscribe to protect your connection on up to 3 devices.'
                  : 'Subscribe on vulcainvpn.com, or on the Android app, then pull to refresh.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),
            _primaryButton('Subscribe', Icons.shopping_cart, _openRenewalPage),
          ],
        ),
      );
    }

    final sub = _subscriptionData?['subscription'];
    if (sub == null) {
      return Center(child: Text(loc.noSubscriptionData));
    }
    final isGooglePlay = sub['source'] == 'google_play';

    final plan = sub['plan'] ?? {};
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
      onRefresh: () => _loadSubscription(force: true),
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

          // Google Play subscriptions are managed (cancelled) in Google Play
          if (isGooglePlay && !isExpired) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openPlaySubscriptions,
                icon: const Icon(Icons.open_in_new, color: MyColors.myOrange, size: 18),
                label: const Text('Manage in Google Play', style: TextStyle(color: MyColors.myOrange)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: MyColors.myOrange),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],

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
