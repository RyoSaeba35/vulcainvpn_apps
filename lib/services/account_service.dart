import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'language_service.dart';
import '../l10n/auth_strings.dart';

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
      return AccountResult(false, AuthStrings.current.invalidEmail);
    }
    if (password.length < minPasswordLength) {
      return AccountResult(false, AuthStrings.current.passwordTooShort(minPasswordLength));
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
      return AccountResult(false, AuthStrings.current.invalidEmail);
    }
    return _post('password/reset', {'email': sanitizedEmail});
  }

  /// POST /api/confirmation/resend
  static Future<AccountResult> resendConfirmation(String email) async {
    final sanitizedEmail = email.trim().toLowerCase();
    if (!isValidEmail(sanitizedEmail)) {
      return AccountResult(false, AuthStrings.current.invalidEmail);
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
      return AccountResult(false, AuthStrings.current.invalidLink);
    }

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/confirmation'),
            headers: {'Content-Type': 'application/json', ...LanguageService.headers},
            body: json.encode({'confirmation_token': token}),
          )
          .timeout(_timeout);

      try {
        lastConfirmedEmail = (json.decode(response.body) as Map<String, dynamic>)['email'] as String?;
      } catch (_) {}

      return _toResult(response, successCodes: const [200]);
    } catch (e) {
      print('❌ Confirm email error: $e');
      return AccountResult(false, AuthStrings.current.connectionErrorLink);
    }
  }

  /// DELETE /api/account. Requires the current password.
  /// On success the caller must clear the local session (AuthService.logout).
  /// For accounts created with Google, pass [googleIdToken] instead of a password.
  static Future<AccountResult> deleteAccount(String password, {String? googleIdToken}) async {
    if (password.isEmpty && googleIdToken == null) {
      return AccountResult(false, AuthStrings.current.enterPassword);
    }

    final token = await AuthService.getValidAccessToken();
    if (token == null) {
      return AccountResult(false, AuthStrings.current.sessionExpired);
    }

    try {
      final response = await http
          .delete(
            Uri.parse('$_baseUrl/account'),
            headers: {
              'Content-Type': 'application/json',
              ...LanguageService.headers,
              'Authorization': 'Bearer $token',
            },
            body: json.encode(googleIdToken != null
                ? {'google_id_token': googleIdToken}
                : {'password': password}),
          )
          .timeout(_timeout);

      return _toResult(response, successCodes: const [200]);
    } catch (e) {
      print('❌ Delete account error: $e');
      return AccountResult(false, AuthStrings.current.connectionError);
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
            headers: {'Content-Type': 'application/json', ...LanguageService.headers},
            body: json.encode(body),
          )
          .timeout(_timeout);

      return _toResult(response, successCodes: successCodes);
    } catch (e) {
      print('❌ $endpoint error: $e');
      return AccountResult(false, AuthStrings.current.connectionError);
    }
  }

  static AccountResult _toResult(http.Response response,
      {required List<int> successCodes}) {
    Map<String, dynamic> data = {};
    try {
      data = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    if (successCodes.contains(response.statusCode)) {
      return AccountResult(true, (data['message'] as String?) ?? AuthStrings.current.done);
    }

    if (response.statusCode == 429) {
      return AccountResult(false, AuthStrings.current.tooManyAttempts);
    }

    return AccountResult(
        false, (data['error'] as String?) ?? AuthStrings.current.somethingWrong);
  }
}
