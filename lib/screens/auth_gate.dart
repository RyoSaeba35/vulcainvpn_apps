import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/account_service.dart';
import '../services/deep_link_service.dart';
import '../services/language_service.dart';
import '../l10n/auth_strings.dart';
import '../main.dart';
import '../services/billing_service.dart';
import '../colors.dart';
import 'login_screen.dart';
import 'vpn_home_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  String? _sessionResetReason; // Non-null when keystore was wiped unexpectedly

  // Email confirmation opened from the email link (Android App Links)
  bool _isConfirming = false;
  String? _loginEmail;
  String? _loginMessage;
  bool _loginMessageIsError = false;
  int _loginScreenVersion = 0; // Rebuilds LoginScreen with the new prefill

  @override
  void initState() {
    super.initState();
    _checkAuth();
    DeepLinkService.listen(_onConfirmationLink);
    // Google Play purchases finished while the app was closed (Android only)
    BillingService.instance.start();
  }

  @override
  void dispose() {
    DeepLinkService.dispose();
    super.dispose();
  }

  bool _languageLoaded = false;

  /// Saves the language whenever it changes (sign in screen picker or
  /// Settings > Language) so it is kept on the next launch.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final code = Localizations.localeOf(context).languageCode;
    if (_languageLoaded && code != AuthStrings.code) {
      LanguageService.save(code);
    }
  }

  Future<void> _checkAuth() async {
    // Language first: messages built while checking the session use it
    final locale = await LanguageService.load();
    if (mounted) MyApp.setLocale(context, locale);
    _languageLoaded = true;

    final loggedIn = await AuthService.isLoggedIn();
    // Read reset reason AFTER isLoggedIn() — it's set inside that call
    final resetReason = await AuthService.getSessionResetReason();
    if (mounted) {
      setState(() {
        _isLoggedIn = loggedIn;
        _sessionResetReason = resetReason;
        _isLoading = false;
      });
    }
  }

  Future<void> _onConfirmationLink(String token) async {
    if (!mounted) return;

    // Close sign up / forgot password screens so the result shows on login
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _isConfirming = true);

    final result = await AccountService.confirmEmail(token);
    if (!mounted) return;

    if (_isLoggedIn) {
      // Rare: link opened while signed in (e.g. email change). Just inform.
      setState(() => _isConfirming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    setState(() {
      _isConfirming = false;
      _loginEmail = AccountService.lastConfirmedEmail;
      _loginMessage = result.message;
      _loginMessageIsError = !result.ok;
      _sessionResetReason = null;
      _loginScreenVersion++;
    });
  }

  void _onLoginSuccess() {
    setState(() {
      _isLoggedIn = true;
      _sessionResetReason = null;
      _loginEmail = null;
      _loginMessage = null;
    });
  }

  void _onLogout() async {
    await AuthService.logout();
    if (mounted) {
      setState(() {
        _isLoggedIn = false;
        _sessionResetReason = null;
        _loginScreenVersion++;
      });
    }
  }

  Widget _loadingScreen({String? text}) {
    return Scaffold(
      backgroundColor: MyColors.myBrown,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: MyColors.myOrange),
            if (text != null) ...[
              const SizedBox(height: 20),
              Text(text, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _loadingScreen();

    if (_isConfirming && !_isLoggedIn) {
      return _loadingScreen(text: AuthStrings.of(context).confirmingEmail);
    }

    if (!_isLoggedIn) {
      return LoginScreen(
        key: ValueKey(_loginScreenVersion),
        onLoginSuccess: _onLoginSuccess,
        sessionResetReason: _sessionResetReason,
        initialEmail: _loginEmail,
        initialInfoMessage: _loginMessage,
        initialInfoIsError: _loginMessageIsError,
      );
    }

    return VpnHomePage(onLogout: _onLogout);
  }
}
