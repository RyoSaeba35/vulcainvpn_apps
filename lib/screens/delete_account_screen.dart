import 'package:flutter/material.dart';
import '../services/account_service.dart';
import '../services/google_auth_service.dart';
import '../colors.dart';
import '../widgets/auth_ui.dart';
import '../l10n/auth_strings.dart';

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

  // Accounts created with "Continue with Google" have no password to type
  Future<void> _deleteWithGoogle() async {
    if (!_understood) {
      setState(() => _errorMessage = AuthStrings.of(context).pleaseConfirmUnderstand);
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final idToken = await GoogleAuthService.getIdToken();
      if (idToken == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      final result = await AccountService.deleteAccount('', googleIdToken: idToken);
      if (!mounted) return;
      if (result.ok) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = result.message;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = AuthStrings.of(context).googleConfirmUnavailable;
      });
    }
  }

  Future<void> _delete() async {
    if (!_understood) {
      setState(() => _errorMessage = AuthStrings.of(context).pleaseConfirmUnderstand);
      return;
    }

    // No password typed: on Android this is usually a Google account, so
    // confirm with Google directly instead of showing "password required"
    if (_passwordController.text.isEmpty) {
      if (GoogleAuthService.isSupported) {
        await _deleteWithGoogle();
      } else {
        setState(() => _errorMessage = AuthStrings.of(context).enterPassword);
      }
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
    final s = AuthStrings.of(context);
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
                AuthUi.title(s.deleteTitle),
                const SizedBox(height: 24),

                _bullet(s.deleteBullet1),
                _bullet(s.deleteBullet2),
                _bullet(s.deleteBullet3),
                const SizedBox(height: 4),
                Text(
                  s.deletePlayNote,
                  style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 24),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  enabled: !_isLoading,
                  style: const TextStyle(color: Colors.white),
                  decoration: AuthUi.input(
                    s.confirmWithPassword,
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
                  title: Text(
                    s.iUnderstand,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 8),

                if (_errorMessage != null) AuthUi.message(_errorMessage!, error: true),

                AuthButton(
                  label: s.deletePermanently,
                  onPressed: _delete,
                  loading: _isLoading,
                  color: Colors.red,
                ),

                // Signed up with Google: confirm with Google instead of a password
                if (GoogleAuthService.isSupported) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _isLoading ? null : _deleteWithGoogle,
                    child: Text(
                      s.confirmWithGoogle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _isLoading ? null : () => Navigator.pop(context, false),
                  child: Text(s.cancel, style: const TextStyle(color: Colors.white60, fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
