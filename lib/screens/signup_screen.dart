import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/account_service.dart';
import '../colors.dart';

/// Account creation. On success, shows a "check your email" step; the user
/// confirms by email, then signs in. Pops with the email so the login screen
/// can prefill it.
class SignupScreen extends StatefulWidget {
  final String? initialEmail;

  const SignupScreen({super.key, this.initialEmail});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  late final TextEditingController _emailController;
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _acceptedTerms = false;
  String? _errorMessage;

  // Set once the account is created: switches to the "check your email" view
  String? _createdEmail;
  String? _infoMessage;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (!AccountService.isValidEmail(email)) {
      setState(() => _errorMessage = 'Please enter a valid email address.');
      return;
    }
    if (password.length < AccountService.minPasswordLength) {
      setState(() => _errorMessage =
          'Password must be at least ${AccountService.minPasswordLength} characters.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }
    if (!_acceptedTerms) {
      setState(() => _errorMessage =
          'Please accept the Terms of Service and Privacy Policy.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AccountService.signUp(email, password);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.ok) {
        _createdEmail = email.toLowerCase();
        _infoMessage = null;
        _passwordController.clear();
        _confirmController.clear();
      } else {
        _errorMessage = result.message;
      }
    });
  }

  Future<void> _resendConfirmation() async {
    if (_createdEmail == null) return;
    setState(() => _isLoading = true);

    final result = await AccountService.resendConfirmation(_createdEmail!);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _infoMessage = result.message;
    });
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  InputDecoration _decoration(String label, IconData icon, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      prefixIcon: Icon(icon, color: Colors.white54),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white24),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: MyColors.myOrange),
      ),
      filled: true,
      fillColor: Colors.white.withOpacity(0.05),
    );
  }

  Widget _primaryButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: _isLoading ? null : onPressed,
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
                label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MyColors.myBrown,
      appBar: AppBar(
        backgroundColor: MyColors.myBrown,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _createdEmail),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _createdEmail == null ? _buildForm() : _buildCheckEmail(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Create your account',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'One account for all your devices',
          style: TextStyle(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 32),

        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          style: const TextStyle(color: Colors.white),
          decoration: _decoration('Email', Icons.email_outlined),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          style: const TextStyle(color: Colors.white),
          decoration: _decoration(
            'Password (min. ${AccountService.minPasswordLength} characters)',
            Icons.lock_outline,
            suffix: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
                color: Colors.white54,
              ),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _confirmController,
          obscureText: _obscurePassword,
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _signUp(),
          decoration: _decoration('Confirm password', Icons.lock_outline),
        ),
        const SizedBox(height: 12),

        // Terms acceptance
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _acceptedTerms,
              onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
              activeColor: MyColors.myOrange,
              side: const BorderSide(color: Colors.white54),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    children: [
                      const TextSpan(text: 'I accept the '),
                      TextSpan(
                        text: 'Terms of Service',
                        style: const TextStyle(
                          color: Colors.white,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => _openUrl('https://www.vulcainvpn.com/terms'),
                      ),
                      const TextSpan(text: ' and the '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: const TextStyle(
                          color: Colors.white,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => _openUrl('https://www.vulcainvpn.com/privacy'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),

        _primaryButton('Create account', _signUp),
        const SizedBox(height: 20),

        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Already have an account? Sign in',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckEmail() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.mark_email_read_outlined, size: 72, color: MyColors.myOrange),
        const SizedBox(height: 20),
        const Text(
          'Check your email',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'We sent a confirmation link to\n$_createdEmail\n\n'
          'Open it to activate your account, then come back and sign in. '
          'Check your spam folder if you don\'t see it.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 28),

        _primaryButton('Go to sign in', () => Navigator.pop(context, _createdEmail)),
        const SizedBox(height: 12),

        TextButton(
          onPressed: _isLoading ? null : _resendConfirmation,
          child: const Text(
            'Resend confirmation email',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ),

        if (_infoMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _infoMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
