import 'package:flutter/material.dart';
import '../colors.dart';

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

  static AppBar appBar(BuildContext context, {VoidCallback? onBack}) {
    return AppBar(
      backgroundColor: MyColors.myBrown,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
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
