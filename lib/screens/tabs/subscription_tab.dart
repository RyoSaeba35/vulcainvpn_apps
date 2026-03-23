import 'package:flutter/material.dart';
import '../../colors.dart';
import '../../services/api_service.dart';
import '../../widgets/info_card.dart';
import '../../widgets/info_row.dart';

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
          InfoCard(
            title: 'Subscription',
            icon: Icons.card_membership,
            children: [
              InfoRow(
                label: 'Plan',
                value: '${plan['name'] ?? '-'} — ${plan['interval'] ?? '-'}',
              ),
              InfoRow(
                label: 'Reference',
                value: sub['name'] ?? '-',
              ),
              InfoRow(
                label: 'Status',
                value: sub['status'] ?? '-',
                valueColor:
                    sub['status'] == 'active' ? Colors.green : Colors.red,
              ),
              InfoRow(
                label: 'Expires',
                value: expiresAt != null
                    ? '${expiresAt.day}/${expiresAt.month}/${expiresAt.year}'
                    : '-',
              ),
              InfoRow(
                label: 'Days remaining',
                value: '$daysRemaining days',
                valueColor: daysRemaining < 7 ? Colors.red : Colors.green,
              ),
            ],
          ),
          const SizedBox(height: 16),
          InfoCard(
            title: 'Server',
            icon: Icons.dns_outlined,
            children: [
              InfoRow(label: 'Location', value: server['name'] ?? '-'),
            ],
          ),
          const SizedBox(height: 16),
          InfoCard(
            title: 'Devices',
            icon: Icons.devices_outlined,
            children: [
              InfoRow(
                label: 'Active connections',
                value: '$activeDevices / $maxDevices',
                valueColor:
                    activeDevices >= maxDevices ? Colors.red : Colors.green,
              ),
              InfoRow(
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
