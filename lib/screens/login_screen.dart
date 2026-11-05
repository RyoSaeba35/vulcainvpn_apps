import 'package:flutter/material.dart';
import 'dart:io';
import '../services/auth_service.dart';
import '../services/account_service.dart';
import '../colors.dart';
import 'signup_screen.dart';
import 'forgot_password_screen.dart';
import '../services/google_auth_service.dart';
import '../widgets/auth_ui.dart';
import '../l10n/auth_strings.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

// Only import window_manager on desktop platforms
import 'package:window_manager/window_manager.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;
  final String? sessionResetReason;

  /// Prefill + message, e.g. after confirming the email from the link
  final String? initialEmail;
  final String? initialInfoMessage;
  final bool initialInfoIsError;

  const LoginScreen({
    super.key,
    required this.onLoginSuccess,
    this.sessionResetReason,
    this.initialEmail,
    this.initialInfoMessage,
    this.initialInfoIsError = false,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WindowListener {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  String? _infoMessage;
  bool _needsConfirmation = false;
  bool _isGoogleLoading = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null) _emailController.text = widget.initialEmail!;
    if (widget.initialInfoMessage != null) {
      if (widget.initialInfoIsError) {
        _errorMessage = widget.initialInfoMessage;
        _needsConfirmation = true; // invalid/expired link: offer to resend
      } else {
        _infoMessage = widget.initialInfoMessage;
      }
    }
    if (_isDesktop) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Handle window close button on desktop
  @override
  void onWindowClose() async {
    await windowManager.destroy();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = AuthStrings.of(context).enterEmailAndPassword);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _infoMessage = null;
      _needsConfirmation = false;
    });

    final success = await AuthService.login(email, password);

    if (!mounted) return;

    if (success) {
      widget.onLoginSuccess();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = AuthService.lastLoginError ?? AuthStrings.of(context).invalidCredentials;
        _needsConfirmation = AuthService.lastLoginNeedsConfirmation;
      });
    }
  }

  Future<void> _loginWithGoogle() async {
    setState(() {
      _isGoogleLoading = true;
      _errorMessage = null;
      _infoMessage = null;
      _needsConfirmation = false;
    });

    try {
      final idToken = await GoogleAuthService.getIdToken();
      if (idToken == null) {
        // User closed the Google account picker
        if (mounted) setState(() => _isGoogleLoading = false);
        return;
      }

      var success = await AuthService.loginWithGoogle(idToken);
      if (!mounted) return;

      // No Vulcain account for this Google account yet: ask before creating
      // one (e.g. someone who deleted their account must know it's a new one)
      final newEmail = AuthService.lastGoogleNoAccountEmail;
      if (!success && newEmail != null) {
        final create = await _confirmNewGoogleAccount(newEmail);
        if (!mounted) return;
        if (create != true) {
          await GoogleAuthService.signOut();
          if (mounted) setState(() => _isGoogleLoading = false);
          return;
        }
        success = await AuthService.loginWithGoogle(idToken, create: true);
        if (!mounted) return;
      }

      if (success) {
        widget.onLoginSuccess();
      } else {
        setState(() {
          _isGoogleLoading = false;
          _errorMessage = AuthService.lastLoginError ?? AuthStrings.of(context).googleFailed;
        });
      }
    } catch (e) {
      print('❌ Google sign-in error: $e');
      if (!mounted) return;
      setState(() {
        _isGoogleLoading = false;
        _errorMessage = AuthStrings.of(context).googleUnavailable;
      });
    }
  }

  Future<void> _resendConfirmation() async {
    setState(() => _isLoading = true);
    final result = await AccountService.resendConfirmation(_emailController.text);
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _errorMessage = null;
      _needsConfirmation = false;
      _infoMessage = result.message;
    });
  }

  Future<void> _openSignup() async {
    final createdEmail = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => SignupScreen(initialEmail: _emailController.text.trim()),
      ),
    );
    if (!mounted) return;
    if (createdEmail == SignupScreen.googleSignedIn) {
      widget.onLoginSuccess(); // Signed up with Google: already signed in
      return;
    }
    if (createdEmail != null && createdEmail.isNotEmpty) {
      setState(() {
        _emailController.text = createdEmail;
        _passwordController.clear();
        _errorMessage = null;
        _needsConfirmation = false;
        _infoMessage = AuthStrings.of(context).confirmThenSignIn;
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// "Create a Vulcain account?" (styled like the account screens)
  Future<bool?> _confirmNewGoogleAccount(String email) {
    final s = AuthStrings.of(context);
    final linkStyle = const TextStyle(
      color: Colors.white70,
      decoration: TextDecoration.underline,
      decorationColor: Colors.white70,
    );
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF4A3530),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          s.googleNewAccountTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.googleNewAccountBody(email),
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 14),
            RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                children: [
                  TextSpan(text: s.googleNewAccountTerms),
                  const TextSpan(text: '\n'),
                  TextSpan(
                    text: s.termsOfService,
                    style: linkStyle,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _openUrl('https://www.vulcainvpn.com/terms'),
                  ),
                  const TextSpan(text: '  ·  '),
                  TextSpan(
                    text: s.privacyPolicy,
                    style: linkStyle,
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => _openUrl('https://www.vulcainvpn.com/privacy'),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(s.cancel, style: const TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: MyColors.myOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(s.createMyAccount),
          ),
        ],
      ),
    );
  }

  Future<void> _openForgotPassword() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ForgotPasswordScreen(initialEmail: _emailController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AuthStrings.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (_isDesktop) {
          await windowManager.destroy();
        }
        // On mobile, do nothing — user must login or use system back gesture
      },
      child: Scaffold(
        backgroundColor: MyColors.myBrown,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 56, 32, 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Image.asset(
                    'assets/icons/icon.png',
                    width: 80,
                    height: 80,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.vpn_lock,
                      size: 80,
                      color: MyColors.myOrange,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Vulcain VPN',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.signInSubtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                  const SizedBox(height: 40),

                  // ✅ Session reset banner — shown when keystore was wiped
                  // (OS update, device restore, some Samsung/Xiaomi devices)
                  if (widget.sessionResetReason != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 20),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        border: Border.all(color: Colors.orange, width: 1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline,
                              color: Colors.orange, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.sessionResetReason!,
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Continue with Google (Android only)
                  if (GoogleAuthService.isSupported) ...[
                    GoogleButton(
                      onPressed: _isLoading ? null : _loginWithGoogle,
                      loading: _isGoogleLoading,
                    ),
                    const OrDivider(),
                  ],

                  // Email field
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: s.email,
                      labelStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(
                        Icons.email_outlined,
                        color: Colors.white54,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: MyColors.myOrange),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Password field
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    style: const TextStyle(color: Colors.white),
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      labelText: s.password,
                      labelStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(
                        Icons.lock_outline,
                        color: Colors.white54,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: Colors.white54,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: MyColors.myOrange),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  // Forgot password
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _isLoading ? null : _openForgotPassword,
                      child: Text(
                        s.forgotPassword,
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ),
                  ),

                  // Error message
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                      ),
                    ),

                  // Email not confirmed yet: offer to resend the link
                  if (_needsConfirmation)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextButton(
                        onPressed: _isLoading ? null : _resendConfirmation,
                        child: Text(
                          s.resendConfirmation,
                          style: const TextStyle(
                            color: MyColors.myOrange,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                  // Info message (email sent, account created...)
                  if (_infoMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _infoMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ),

                  // Login button
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MyColors.myOrange,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text(
                              s.signIn,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Create account
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        s.noAccount,
                        style: const TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                      GestureDetector(
                        onTap: _isLoading ? null : _openSignup,
                        child: Text(
                          s.createOne,
                          style: const TextStyle(
                            color: MyColors.myOrange,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Google sign-in exists on Android and the website only
                  if (_isDesktop) ...[
                    const SizedBox(height: 16),
                    Text(
                      s.windowsGoogleHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                    ),
                  ],
                ],
              ),
            ),
          ),
              // Language (English / Français)
              const Positioned(top: 12, right: 16, child: LanguagePicker()),
            ],
          ),
        ),
      ),
    );
  }
}
