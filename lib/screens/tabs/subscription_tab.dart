import 'package:flutter/material.dart';
import 'dart:io';
import '../../colors.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/info_card.dart';
import '../../widgets/info_row.dart';
import '../../l10n/app_localizations.dart';

class SubscriptionTab extends StatefulWidget {
  const SubscriptionTab({super.key});

  @override
  State<SubscriptionTab> createState() => _SubscriptionTabState();
}

class _SubscriptionTabState extends State<SubscriptionTab> {
  Map<String, dynamic>? _subscriptionData;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  // ✅ FIX: Console logging only (no Windows file writing to prevent hangs)
  Future<void> _log(String message) async {
    print(message);

    /* ORIGINAL FILE LOGGING (disabled to prevent Windows issues):
    try {
      final timestamp = DateTime.now().toIso8601String();
      final logMessage = '$timestamp: $message\n';

      if (Platform.isWindows) {
        final logPath = '${Platform.environment['USERPROFILE']}\\Documents\\VulcainVPN_Subscription.log';
        final logFile = File(logPath);
        await logFile.writeAsString(logMessage, mode: FileMode.append);
      }

      print(message);
    } catch (e) {
      print('Failed to write log: $e');
    }
    */
  }

  Future<void> _loadSubscription() async {
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
        await _log('   Token preview: ${token.substring(0, token.length > 20 ? 20 : token.length)}...');
      } else {
        await _log('   ❌ No token found!');
      }

      // Try to fetch subscription
      await _log('   Calling API...');
      final data = await ApiService.fetchSubscription();
      await _log('   ✅ Subscription data received');
      await _log('   Data keys: ${data.keys.toList()}');

      // ✅ FIX: Check if widget is still mounted before calling setState
      if (!mounted) return;

      setState(() {
        _subscriptionData = data;
        _isLoading = false;
      });
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

  @override
  Widget build(BuildContext context) {
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

    return RefreshIndicator(
      onRefresh: _loadSubscription,
      color: MyColors.myOrange,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          InfoCard(
            title: loc.subscription,
            icon: Icons.card_membership,
            children: [
              InfoRow(
                label: loc.plan,
                value: '${plan['name'] ?? '-'} — ${plan['interval'] ?? '-'}',
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
            title: loc.server,
            icon: Icons.dns_outlined,
            children: [
              InfoRow(label: loc.location, value: server['name'] ?? '-'),
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
        ],
      ),
    );
  }
}
