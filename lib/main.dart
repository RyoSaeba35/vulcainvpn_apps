import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'colors.dart';
import 'l10n/app_localizations.dart';
import 'screens/auth_gate.dart';
import 'services/security_checker.dart';
import 'services/vpn_service_android.dart';
import 'services/notification_service.dart';
import 'services/windows_notification_service.dart';
import 'services/macos_notification_service.dart';
import 'services/auth_service.dart';
import 'services/vpn_service_ios.dart';

// 🔐 Release builds must not log personal data. The code has many print()
// calls (emails, device IDs, even the full API key at registration), and on
// Android Flutter forwards every print() to the system log (logcat), which
// other tools and anyone with USB access can read.
//
// Instead of editing hundreds of lines, every print() in the app runs inside
// this zone: debug and profile builds print as before, release builds print
// nothing. The Android diagnostic report is unaffected: it uses the native
// VpnLogger file, not print().
void main() {
  runZoned(
    _main,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (!kReleaseMode) parent.print(zone, line);
      },
    ),
  );
}

// Everything (including ensureInitialized and runApp) stays inside the same
// zone, as Flutter requires.
Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Licenses not discovered automatically (shown in Settings > Open Source Licences)
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Vulcain VPN'], _appLicense);
    yield const LicenseEntryWithLineBreaks(['sing-box'], _singBoxLicense);
  });

  await AuthService.initialize();

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

  if (Platform.isIOS) {
    IosVpnService.setupEventListener();
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


const String _appLicense = '''Vulcain VPN client
Copyright (C) 2026 Pierre Libran

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: https://www.gnu.org/licenses/gpl-3.0.html

Source code: https://github.com/RyoSaeba35/cross_platform_vpn

The "Vulcain VPN" name and logo are not licensed under the GPL.''';

const String _singBoxLicense = '''Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: https://www.gnu.org/licenses/gpl-3.0.html

In addition, no derivative work may use the name or imply association with this application without prior consent.

Source code: https://github.com/SagerNet/sing-box''';
