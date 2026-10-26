import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_service.dart';

/// Result of an account API call: [ok] plus a message to show the user.
class AccountResult {
  final bool ok;
  final String message;
  const AccountResult(this.ok, this.message);
}

/// Sign up, confirmation/password emails and account deletion.
/// Login, refresh and logout stay in [AuthService].
class AccountService {
  static const String _baseUrl = 'https://api.vulcainvpn.com/api';
  static const Duration _timeout = Duration(seconds: 15);
  static const int minPasswordLength = 8; // Must match Devise password_length

  static final RegExp _emailRegex = RegExp(r'^[\w\-\.+]+@([\w\-]+\.)+[\w\-]{2,}$');

  static bool isValidEmail(String email) => _emailRegex.hasMatch(email.trim());

  /// POST /api/signup. The account must be confirmed by email before login.
  static Future<AccountResult> signUp(String email, String password) async {
    final sanitizedEmail = email.trim().toLowerCase();

    if (!isValidEmail(sanitizedEmail)) {
      return const AccountResult(false, 'Please enter a valid email address.');
    }
    if (password.length < minPasswordLength) {
      return const AccountResult(
          false, 'Password must be at least $minPasswordLength characters.');
    }

    return _post('signup', {
      'email': sanitizedEmail,
      'password': password,
      'password_confirmation': password,
    }, successCodes: const [201]);
  }

  /// POST /api/password/reset. Always succeeds (server does not reveal accounts).
  static Future<AccountResult> requestPasswordReset(String email) async {
    final sanitizedEmail = email.trim().toLowerCase();
    if (!isValidEmail(sanitizedEmail)) {
      return const AccountResult(false, 'Please enter a valid email address.');
    }
    return _post('password/reset', {'email': sanitizedEmail});
  }

  /// POST /api/confirmation/resend
  static Future<AccountResult> resendConfirmation(String email) async {
    final sanitizedEmail = email.trim().toLowerCase();
    if (!isValidEmail(sanitizedEmail)) {
      return const AccountResult(false, 'Please enter a valid email address.');
    }
    return _post('confirmation/resend', {'email': sanitizedEmail});
  }

  /// POST /api/confirmation with the token from the email link (App Links).
  /// On success, [AccountResult.message] is shown and the returned email is
  /// available in [lastConfirmedEmail] to prefill the login screen.
  static String? lastConfirmedEmail;

  static Future<AccountResult> confirmEmail(String token) async {
    lastConfirmedEmail = null;
    if (token.isEmpty) {
      return const AccountResult(false, 'This confirmation link is invalid.');
    }

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/confirmation'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'confirmation_token': token}),
          )
          .timeout(_timeout);

      try {
        lastConfirmedEmail = (json.decode(response.body) as Map<String, dynamic>)['email'] as String?;
      } catch (_) {}

      return _toResult(response, successCodes: const [200]);
    } catch (e) {
      print('❌ Confirm email error: $e');
      return const AccountResult(
          false, 'Connection error. Check your internet and open the link again.');
    }
  }

  /// DELETE /api/account. Requires the current password.
  /// On success the caller must clear the local session (AuthService.logout).
  static Future<AccountResult> deleteAccount(String password) async {
    if (password.isEmpty) {
      return const AccountResult(false, 'Please enter your password.');
    }

    final token = await AuthService.getValidAccessToken();
    if (token == null) {
      return const AccountResult(
          false, 'Your session has expired. Please sign in again, then retry.');
    }

    try {
      final response = await http
          .delete(
            Uri.parse('$_baseUrl/account'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({'password': password}),
          )
          .timeout(_timeout);

      return _toResult(response, successCodes: const [200]);
    } catch (e) {
      print('❌ Delete account error: $e');
      return const AccountResult(
          false, 'Connection error. Check your internet and try again.');
    }
  }

  static Future<AccountResult> _post(
    String endpoint,
    Map<String, dynamic> body, {
    List<int> successCodes = const [200],
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(_timeout);

      return _toResult(response, successCodes: successCodes);
    } catch (e) {
      print('❌ $endpoint error: $e');
      return const AccountResult(
          false, 'Connection error. Check your internet and try again.');
    }
  }

  static AccountResult _toResult(http.Response response,
      {required List<int> successCodes}) {
    Map<String, dynamic> data = {};
    try {
      data = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    if (successCodes.contains(response.statusCode)) {
      return AccountResult(true, (data['message'] as String?) ?? 'Done.');
    }

    if (response.statusCode == 429) {
      return const AccountResult(
          false, 'Too many attempts. Please wait a moment and try again.');
    }

    return AccountResult(
        false, (data['error'] as String?) ?? 'Something went wrong. Please try again.');
  }
}
