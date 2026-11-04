import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../colors.dart';
import '../widgets/auth_ui.dart';
import '../l10n/auth_strings.dart';

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
      appBar: AuthUi.appBar(context, actions: const [
        Padding(padding: EdgeInsets.only(right: 16), child: Center(child: LanguagePicker())),
      ]),
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
    final s = AuthStrings.of(context);
    return Column(
      children: [
        const Icon(Icons.lock_reset, size: 64, color: MyColors.myOrange),
        const SizedBox(height: 20),
        AuthUi.title(s.resetTitle, subtitle: s.resetSubtitle),
        const SizedBox(height: 32),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _send(),
          decoration: AuthUi.input(s.email, Icons.email_outlined),
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) AuthUi.message(_errorMessage!, error: true),
        AuthButton(label: s.sendResetLink, onPressed: _send, loading: _isLoading),
      ],
    );
  }

  Widget _buildSent() {
    final s = AuthStrings.of(context);
    return Column(
      children: [
        const Icon(Icons.mark_email_read_outlined, size: 72, color: MyColors.myOrange),
        const SizedBox(height: 20),
        AuthUi.title(s.checkYourEmail, subtitle: s.resetSent(_emailController.text.trim())),
        const SizedBox(height: 28),
        AuthButton(label: s.backToSignIn, onPressed: () => Navigator.pop(context)),
      ],
    );
  }
}
