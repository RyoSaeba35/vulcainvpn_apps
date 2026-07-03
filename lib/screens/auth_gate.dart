import 'package:flutter/material.dart';
import '../services/auth_service.dart';
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

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
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

  void _onLoginSuccess() {
    setState(() {
      _isLoggedIn = true;
      _sessionResetReason = null;
    });
  }

  void _onLogout() async {
    await AuthService.logout();
    if (mounted) {
      setState(() {
        _isLoggedIn = false;
        _sessionResetReason = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: MyColors.myBrown,
        body: Center(
          child: CircularProgressIndicator(color: MyColors.myOrange),
        ),
      );
    }

    if (!_isLoggedIn) {
      return LoginScreen(
        onLoginSuccess: _onLoginSuccess,
        sessionResetReason: _sessionResetReason,
      );
    }

    return VpnHomePage(onLogout: _onLogout);
  }
}
