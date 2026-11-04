import 'package:flutter/material.dart';
import '../colors.dart';
import '../l10n/auth_strings.dart';
import '../main.dart';

/// Shared look for the account screens (login, sign up, forgot password,
/// delete account): brown background, white text, orange accents.
class AuthUi {
  static InputDecoration input(String label, IconData icon, {Widget? suffix, String? errorText}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      errorText: errorText,
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
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
    );
  }

  static AppBar appBar(BuildContext context, {VoidCallback? onBack, List<Widget>? actions}) {
    return AppBar(
      backgroundColor: MyColors.myBrown,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
      actions: actions,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: onBack ?? () => Navigator.pop(context),
      ),
    );
  }

  static Widget title(String text, {String? subtitle}) {
    return Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.4),
          ),
        ],
      ],
    );
  }

  static Widget message(String text, {bool error = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: error ? Colors.redAccent : Colors.white70, fontSize: 13),
      ),
    );
  }
}

/// Full-width rounded button with a loading state.
class AuthButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final Color color;

  const AuthButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.color = MyColors.myOrange,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// White "Continue with Google" button (Android sign in / sign up).
class GoogleButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final String? label;

  const GoogleButton({
    super.key,
    required this.onPressed,
    this.loading = false,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF3C4043),
          disabledBackgroundColor: Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3C4043)),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'G',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF4285F4)),
                  ),
                  const SizedBox(width: 12),
                  Text(label ?? AuthStrings.of(context).continueWithGoogle,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
      ),
    );
  }
}

/// "or" separator between Google and email/password
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(AuthStrings.of(context).or,
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ),
          const Expanded(child: Divider(color: Colors.white24)),
        ],
      ),
    );
  }
}

/// "EN / FR" language switch for the account screens. The choice is saved by
/// AuthGate (LanguageService) and shared with Settings > Language.
class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key});

  static const Map<String, String> _names = {'en': '🇬🇧  English', 'fr': '🇫🇷  Français'};

  @override
  Widget build(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode == 'fr' ? 'fr' : 'en';
    return PopupMenuButton<String>(
      tooltip: AuthStrings.of(context).languageLabel,
      color: const Color(0xFF4A3530),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) {
        if (value != code) MyApp.setLocale(context, Locale(value));
      },
      itemBuilder: (_) => [
        for (final entry in _names.entries)
          PopupMenuItem<String>(
            value: entry.key,
            child: Row(
              children: [
                Expanded(child: Text(entry.value, style: const TextStyle(color: Colors.white))),
                if (entry.key == code) const Icon(Icons.check, size: 18, color: MyColors.myOrange),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 18, color: Colors.white70),
            const SizedBox(width: 6),
            Text(code.toUpperCase(),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
            const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}
