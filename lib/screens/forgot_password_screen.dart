import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../colors.dart';
import '../widgets/auth_ui.dart';

/// Sends the password reset email. The link in the email opens the website,
/// where the user chooses a new password, then signs in again in the app.
class ForgotPasswordScreen extends StatefulWidget {
  final String? initialEmail;

  const ForgotPasswordScreen({super.key, this.initialEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _emailController;
  bool _isLoading = false;
  bool _sent = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AccountService.requestPasswordReset(_emailController.text);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.ok) {
        _sent = true;
      } else {
        _errorMessage = result.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MyColors.myBrown,
      appBar: AuthUi.appBar(context),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _sent ? _buildSent() : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        const Icon(Icons.lock_reset, size: 64, color: MyColors.myOrange),
        const SizedBox(height: 20),
        AuthUi.title(
          'Reset your password',
          subtitle: 'Enter your account email. We will send you a link to choose a new password.',
        ),
        const SizedBox(height: 32),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _send(),
          decoration: AuthUi.input('Email', Icons.email_outlined),
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) AuthUi.message(_errorMessage!, error: true),
        AuthButton(label: 'Send reset link', onPressed: _send, loading: _isLoading),
      ],
    );
  }

  Widget _buildSent() {
    return Column(
      children: [
        const Icon(Icons.mark_email_read_outlined, size: 72, color: MyColors.myOrange),
        const SizedBox(height: 20),
        AuthUi.title(
          'Check your email',
          subtitle: 'If an account exists for ${_emailController.text.trim()}, you will receive '
              'a link to choose a new password. Check your spam folder if you don\'t see it.\n\n'
              'Then come back here and sign in with your new password.',
        ),
        const SizedBox(height: 28),
        AuthButton(label: 'Back to sign in', onPressed: () => Navigator.pop(context)),
      ],
    );
  }
}
