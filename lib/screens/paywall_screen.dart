import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/billing_service.dart';
import '../colors.dart';
import '../widgets/auth_ui.dart';
import '../l10n/auth_strings.dart';

/// Android subscription screen (Google Play Billing).
/// Pops with `true` once the backend has activated the subscription.
class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final _billing = BillingService.instance;
  StreamSubscription<BillingEvent>? _eventsSub;

  List<PlanOption> _plans = [];
  PlanOption? _selected;
  bool _isLoading = true;
  bool _isBusy = false;
  String? _errorMessage;
  String? _infoMessage;

  @override
  void initState() {
    super.initState();
    _eventsSub = _billing.events.listen(_onEvent);
    _loadPlans();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPlans() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final plans = await _billing.loadPlans();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        // Preselect the monthly plan
        _selected = plans.isEmpty
            ? null
            : plans.firstWhere((p) => p.period == 'month', orElse: () => plans.first);
        _isLoading = false;
        if (plans.isEmpty) _errorMessage = AuthStrings.of(context).noPlans;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _onEvent(BillingEvent event) {
    if (!mounted) return;
    if (event.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(event.message), behavior: SnackBarBehavior.floating),
      );
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _isBusy = false;
      if (event.pending) {
        _infoMessage = event.message;
        _errorMessage = null;
      } else {
        // Sold out: the orange box already explains it
        _errorMessage = _billing.newSubscriptionsAvailable ? event.message : null;
        _infoMessage = null;
      }
    });
  }

  Future<void> _subscribe() async {
    final plan = _selected;
    if (plan == null) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      await _billing.buy(plan);
      // The result comes back through _onEvent
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = AuthStrings.of(context).couldNotOpenPlay(e);
      });
    }
  }

  Future<void> _restore() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _infoMessage = AuthStrings.of(context).checkingPurchases;
    });
    await _billing.restore();
    // If nothing is found, Google Play sends no event: stop the spinner
    await Future.delayed(const Duration(seconds: 6));
    if (!mounted || !_isBusy) return;
    setState(() {
      _isBusy = false;
      _infoMessage = AuthStrings.of(context).noPurchaseFound;
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _periodLabel(String period) {
    final s = AuthStrings.of(context);
    switch (period) {
      case 'week':
        return s.weekly;
      case 'year':
        return s.yearly;
      default:
        return s.monthly;
    }
  }

  String _perLabel(String period) {
    final s = AuthStrings.of(context);
    switch (period) {
      case 'week':
        return s.perWeek;
      case 'year':
        return s.perYear;
      default:
        return s.perMonth;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AuthStrings.of(context);
    return Scaffold(
      backgroundColor: MyColors.myBrown,
      appBar: AuthUi.appBar(context),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: MyColors.myOrange))
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
                children: [
                  const Icon(Icons.shield_outlined, size: 64, color: MyColors.myOrange),
                  const SizedBox(height: 16),
                  AuthUi.title('Vulcain VPN Premium', subtitle: s.premiumSubtitle),
                  const SizedBox(height: 24),

                  _feature(s.featureUnlimited),
                  _feature(s.featureDevices),
                  _feature(s.featureNoLogs),
                  _feature(s.featureCancel),
                  const SizedBox(height: 24),

                  for (final plan in _plans) _planCard(plan),

                  const SizedBox(height: 8),
                  if (_errorMessage != null) AuthUi.message(_errorMessage!, error: true),
                  if (_infoMessage != null) AuthUi.message(_infoMessage!),

                  // Pool full / maintenance: same rule as the website
                  if (_plans.isNotEmpty && !_billing.newSubscriptionsAvailable) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        border: Border.all(color: Colors.orange),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Text(s.soldOut,
                              style: const TextStyle(
                                  color: Colors.orange, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Text(s.subscriptionsFull,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
                        ],
                      ),
                    ),
                    AuthButton(label: s.tryAgain, onPressed: _loadPlans),
                  ] else if (_plans.isNotEmpty)
                    AuthButton(label: s.subscribe, onPressed: _subscribe, loading: _isBusy)
                  else
                    AuthButton(label: s.tryAgain, onPressed: _loadPlans),

                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _isBusy ? null : _restore,
                    child: Text(s.restorePurchases, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  ),
                  const SizedBox(height: 8),

                  // Subscription terms (required by Google Play)
                  Text(
                    s.subscriptionTerms,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => _open('https://www.vulcainvpn.com/terms'),
                        child: Text(s.terms, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ),
                      const Text('·', style: TextStyle(color: Colors.white38)),
                      TextButton(
                        onPressed: () => _open('https://www.vulcainvpn.com/privacy'),
                        child: Text(s.privacyPolicy, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
      ),
    );
  }

  Widget _feature(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 18, color: MyColors.myOrange),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 14))),
        ],
      ),
    );
  }

  Widget _planCard(PlanOption plan) {
    final selected = identical(plan, _selected);
    return GestureDetector(
      onTap: _isBusy ? null : () => setState(() => _selected = plan),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: selected ? 0.10 : 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? MyColors.myOrange : Colors.white24, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? MyColors.myOrange : Colors.white38,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Text(
                    _periodLabel(plan.period),
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  if (plan.period == 'year') ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: MyColors.myOrange,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        AuthStrings.of(context).bestValue,
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              '${plan.price} ${_perLabel(plan.period)}',
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
