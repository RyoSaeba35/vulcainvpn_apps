import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../colors.dart';
import '../widgets/auth_ui.dart';

/// Permanent account deletion (Google Play requirement).
/// Pops with `true` once the account is deleted; the caller then stops the
/// VPN and clears the local session.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _understood = false;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!_understood) {
      setState(() => _errorMessage = 'Please confirm you understand this cannot be undone.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await AccountService.deleteAccount(_passwordController.text);
    if (!mounted) return;

    if (result.ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = result.message;
      });
    }
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.close, size: 16, color: Colors.redAccent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.3)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MyColors.myBrown,
      appBar: AuthUi.appBar(context, onBack: _isLoading ? () {} : null),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 64, color: Colors.redAccent),
                const SizedBox(height: 20),
                AuthUi.title('Delete your account'),
                const SizedBox(height: 24),

                _bullet('Your account, devices and connection history are permanently deleted.'),
                _bullet('Any remaining subscription time is lost.'),
                _bullet('This cannot be undone.'),
                const SizedBox(height: 4),
                const Text(
                  'A subscription bought on Google Play must also be cancelled in '
                  'Google Play > Payments & subscriptions.',
                  style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 24),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  enabled: !_isLoading,
                  style: const TextStyle(color: Colors.white),
                  decoration: AuthUi.input(
                    'Confirm with your password',
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
                const SizedBox(height: 8),

                CheckboxListTile(
                  value: _understood,
                  onChanged: _isLoading ? null : (v) => setState(() => _understood = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.white54),
                  title: const Text(
                    'I understand my account will be deleted permanently',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 8),

                if (_errorMessage != null) AuthUi.message(_errorMessage!, error: true),

                AuthButton(
                  label: 'Delete permanently',
                  onPressed: _delete,
                  loading: _isLoading,
                  color: Colors.red,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _isLoading ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white60, fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
