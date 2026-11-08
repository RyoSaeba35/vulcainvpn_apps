import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Your free trial has started" message, shown once.
///
/// The backend creates the free trial at the account's first connect and
/// adds `trial_started: {days, expires_at}` to that /api/connect response.
/// startVpn stores it here; the home page shows the message after the
/// connection succeeds. A saved flag makes sure it is shown only once.
class TrialNotice {
  static const String _shownKey = 'trial_notice_shown';

  static int? _pendingDays;
  static DateTime? _pendingExpiresAt;

  /// Called by every platform's startVpn with the /api/connect response.
  static void rememberFromConnect(Map<String, dynamic> response) {
    final trial = response['trial_started'];
    if (trial is! Map) return;

    final days = trial['days'];
    _pendingDays = days is int ? days : int.tryParse('$days');
    _pendingExpiresAt = DateTime.tryParse('${trial['expires_at']}')?.toLocal();
  }

  /// The pending notice (days, expiry) if it was never shown, then cleared.
  static Future<({int days, DateTime? expiresAt})?> take() async {
    final days = _pendingDays;
    final expiresAt = _pendingExpiresAt;
    _pendingDays = null;
    _pendingExpiresAt = null;
    if (days == null) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_shownKey) == true) return null;
      await prefs.setBool(_shownKey, true);
    } catch (e) {
      if (kDebugMode) print('TrialNotice: could not save flag: $e');
    }
    return (days: days, expiresAt: expiresAt);
  }
}
