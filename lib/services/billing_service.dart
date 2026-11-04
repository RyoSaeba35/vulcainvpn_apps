import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'auth_service.dart';
import 'language_service.dart';
import '../l10n/auth_strings.dart';

/// One subscription choice shown on the paywall (a Play base plan).
class PlanOption {
  final ProductDetails details;
  final String basePlanId;
  final String price; // Localized by Google Play, e.g. "4,99 €"
  final String period; // "week" | "month" | "year"

  const PlanOption(this.details, this.basePlanId, this.price, this.period);
}

/// Outcome of a purchase or restore, pushed to whoever is listening (paywall).
class BillingEvent {
  final bool success;
  final bool pending;
  final String message;

  const BillingEvent({required this.success, this.pending = false, required this.message});
}

/// Google Play subscriptions (Android only).
///
/// Flow: the purchase happens in Google Play, the purchase token is sent to
/// our backend (POST /api/purchases/google), which verifies it with Google and
/// activates the subscription. The app never decides on its own that a user
/// is subscribed.
class BillingService {
  BillingService._();
  static final BillingService instance = BillingService._();

  static const String _baseUrl = 'https://api.vulcainvpn.com/api';
  static const Duration _timeout = Duration(seconds: 20);

  final InAppPurchase _iap = InAppPurchase.instance;
  final StreamController<BillingEvent> _events = StreamController<BillingEvent>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  String? _productId;
  String? _accountId;

  /// False when the server is not taking new subscriptions right now
  /// (maintenance, or the VPN pool is full). Same rule as the website.
  bool newSubscriptionsAvailable = true;

  bool get isSupported => Platform.isAndroid;
  Stream<BillingEvent> get events => _events.stream;

  /// Call once at startup on Android: purchases finished while the app was
  /// closed (or pending payments that went through) arrive on this stream.
  void start() {
    if (!isSupported || _purchaseSub != null) return;
    _purchaseSub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (e) => _events.add(BillingEvent(success: false, message: AuthStrings.current.playError(e))),
    );
  }

  /// Product id + obfuscated account id (+ availability) from the backend.
  /// [refresh] re-asks the server: availability changes over time.
  Future<bool> _loadConfig({bool refresh = false}) async {
    if (!refresh && _productId != null && _accountId != null) return true;

    final token = await AuthService.getValidAccessToken();
    if (token == null) return false;

    final response = await http.get(
      Uri.parse('$_baseUrl/billing/config'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(_timeout);

    if (response.statusCode != 200) return false;
    final data = json.decode(response.body) as Map<String, dynamic>;
    _productId = data['product_id'] as String?;
    _accountId = data['account_id'] as String?;
    // Older servers don't send it: treat as open
    newSubscriptionsAvailable = data['available'] != false;
    return _productId != null && _accountId != null;
  }

  /// Base plans of the subscription, cheapest period first.
  /// Throws a readable message when Play or the backend is unavailable.
  Future<List<PlanOption>> loadPlans() async {
    if (!isSupported) return [];
    start();

    if (!await _iap.isAvailable()) {
      throw AuthStrings.current.playUnavailable;
    }
    if (!await _loadConfig(refresh: true)) {
      throw AuthStrings.current.couldNotLoadPlans;
    }

    final response = await _iap.queryProductDetails({_productId!});
    if (response.error != null) {
      throw AuthStrings.current.playError(response.error!.message);
    }

    final plans = <PlanOption>[];
    for (final pd in response.productDetails) {
      if (pd is! GooglePlayProductDetails) continue;
      final index = pd.subscriptionIndex;
      final offers = pd.productDetails.subscriptionOfferDetails;
      if (index == null || offers == null || index >= offers.length) continue;

      final offer = offers[index];
      if (offer.offerId != null) continue; // base plans only (no promo offers for now)

      final billingPeriod = offer.pricingPhases.isNotEmpty ? offer.pricingPhases.last.billingPeriod : '';
      plans.add(PlanOption(pd, offer.basePlanId, pd.price, _periodName(billingPeriod)));
    }

    const order = {'week': 0, 'month': 1, 'year': 2};
    plans.sort((a, b) => (order[a.period] ?? 9).compareTo(order[b.period] ?? 9));
    return plans;
  }

  /// Opens the Google Play purchase sheet. The result arrives on [events].
  Future<void> buy(PlanOption plan) async {
    if (!await _loadConfig(refresh: true)) {
      _events.add(BillingEvent(success: false, message: AuthStrings.current.signInAgainRetry));
      return;
    }
    // Checked again right before paying: the paywall may have been open a while
    if (!newSubscriptionsAvailable) {
      _events.add(BillingEvent(success: false, message: AuthStrings.current.subscriptionsFull));
      return;
    }
    final param = GooglePlayPurchaseParam(
      productDetails: plan.details,
      applicationUserName: _accountId, // Ties the purchase to this Vulcain account
    );
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  /// Re-sends existing Google Play subscriptions to the backend
  /// (new phone, reinstall, or a purchase that was not activated).
  Future<void> restore() async {
    if (!isSupported) return;
    start();
    await _loadConfig();
    await _iap.restorePurchases(applicationUserName: _accountId);
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _events.add(BillingEvent(
            success: false,
            pending: true,
            message: AuthStrings.current.paymentPending,
          ));
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyAndComplete(purchase);
          break;

        case PurchaseStatus.error:
          _events.add(BillingEvent(
            success: false,
            message: purchase.error?.message ?? AuthStrings.current.purchaseFailed,
          ));
          if (purchase.pendingCompletePurchase) await _iap.completePurchase(purchase);
          break;

        case PurchaseStatus.canceled:
          _events.add(BillingEvent(success: false, message: AuthStrings.current.purchaseCancelled));
          if (purchase.pendingCompletePurchase) await _iap.completePurchase(purchase);
          break;
      }
    }
  }

  Future<void> _verifyAndComplete(PurchaseDetails purchase) async {
    final purchaseToken = purchase.verificationData.serverVerificationData;

    try {
      final token = await AuthService.getValidAccessToken();
      if (token == null) {
        // Not signed in: the backend still activates it from Google's
        // notification, and the next restore links it.
        return;
      }

      final response = await http.post(
        Uri.parse('$_baseUrl/purchases/google'),
        headers: {
          'Content-Type': 'application/json',
          ...LanguageService.headers,
          'Authorization': 'Bearer $token',
        },
        body: json.encode({'purchase_token': purchaseToken}),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        // Acknowledge only after the backend has it, so it's never lost
        if (purchase.pendingCompletePurchase) await _iap.completePurchase(purchase);
        _events.add(BillingEvent(success: true, message: AuthStrings.current.subscriptionActive));
      } else {
        String? error;
        try {
          error = json.decode(response.body)['error'] as String?;
        } catch (_) {}
        _events.add(BillingEvent(success: false, message: error ?? AuthStrings.current.couldNotActivate));
      }
    } catch (e) {
      print('❌ Purchase verification error: $e');
      _events.add(BillingEvent(
        success: false,
        message: AuthStrings.current.purchaseSafe,
      ));
    }
  }

  static String _periodName(String iso) {
    switch (iso) {
      case 'P1W':
        return 'week';
      case 'P1Y':
        return 'year';
      default:
        return 'month';
    }
  }
}
