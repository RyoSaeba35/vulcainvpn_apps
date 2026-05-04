import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'colors.dart';
import 'l10n/app_localizations.dart';
import 'screens/auth_gate.dart';
import 'services/security_checker.dart';
import 'services/vpn_service_android.dart';
import 'services/notification_service.dart'; // ✅ NEW: Add this import
import 'services/windows_notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ FIX #8: Check device security before app starts
  final securityAction = await SecurityChecker.evaluateSecurity(
    policy: SecurityPolicy(
      blockRootedDevices: false,   // Warn, don't block
      warnRootedDevices: true,
      blockDebuggers: true,         // Always block debuggers
      blockEmulators: false,
      warnEmulators: false,
    ),
  );

  // ✅ PRIORITY 1: Setup Android event listener
  if (Platform.isAndroid) {
    AndroidVpnService.setupEventListener();

    // ✅ NEW: Initialize notification service
    await NotificationService.initialize();
  }

  // Handle security check result
  if (securityAction == SecurityAction.block) {
    runApp(const SecurityBlockedApp());
    return;
  }

  // Window manager setup (Windows only)
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await WindowsNotificationService.initialize();
    const windowOptions = WindowOptions(
      skipTaskbar: false,
      title: 'Vulcain VPN',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Window manager setup (macOS only)
  if (Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await MacosNotificationService.initialize();
    const windowOptions = WindowOptions(
      skipTaskbar: false,
      title: 'Vulcain VPN',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Start app normally (or with warning)
  runApp(MyApp(
    showSecurityWarning: securityAction == SecurityAction.warn,
  ));
}

class MyApp extends StatefulWidget {
  final bool showSecurityWarning;

  const MyApp({
    super.key,
    this.showSecurityWarning = false,
  });

  @override
  State<MyApp> createState() => _MyAppState();

  static void setLocale(BuildContext context, Locale newLocale) {
    _MyAppState? state = context.findAncestorStateOfType<_MyAppState>();
    state?.setLocale(newLocale);
  }
}

class _MyAppState extends State<MyApp> {
  Locale _locale = const Locale('en');

  void setLocale(Locale locale) {
    setState(() => _locale = locale);
  }

  @override
  void initState() {
    super.initState();

    // ✅ FIX #8: Show security warning if needed
    if (widget.showSecurityWarning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSecurityWarning();
      });
    }
  }

  void _showSecurityWarning() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('Security Warning'),
          ],
        ),
        content: const Text(
          'Your device appears to be rooted/jailbroken. '
          'This may reduce the security of your VPN connection. '
          'Continue at your own risk.',
        ),
        actions: [
          TextButton(
            onPressed: () => exit(0),
            child: const Text('Exit'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Continue Anyway'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vulcain VPN',
      locale: _locale,
      supportedLocales: const [
        Locale('en', ''),
        Locale('fr', ''),
      ],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: MyColors.myOrange),
        useMaterial3: false,
      ),
      home: const AuthGate(),
    );
  }
}

// ✅ FIX #8: Security blocked screen
class SecurityBlockedApp extends StatelessWidget {
  const SecurityBlockedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vulcain VPN - Security Error',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: false,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.security,
                  size: 80,
                  color: Colors.red,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Security Check Failed',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  'This app cannot run on rooted or jailbroken devices '
                  'or while being debugged for security reasons.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () => exit(0),
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('Exit App'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
