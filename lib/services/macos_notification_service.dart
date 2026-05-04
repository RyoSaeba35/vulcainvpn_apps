import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

class MacosNotificationService {
  static bool _initialized = false;
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    if (!Platform.isMacOS) return;
    if (_initialized) return;

    try {
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(macOS: darwinSettings);

      await _notifications.initialize(initSettings);
      _initialized = true;
    } catch (e) {
      print('Failed to initialize macOS notifications: $e');
    }
  }

  static Future<void> showToast({
    required String title,
    required String message,
    bool isError = false,
  }) async {
    if (!Platform.isMacOS) return;

    try {
      await initialize();

      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: true,
      );

      const details = NotificationDetails(macOS: darwinDetails);

      await _notifications.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        message,
        details,
      );
    } catch (e) {
      print('Failed to show macOS notification: $e');
    }
  }

  static Future<void> focusWindow() async {
    if (!Platform.isMacOS) return;

    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
      await Future.delayed(const Duration(milliseconds: 500));
      await windowManager.setAlwaysOnTop(false);
    } catch (e) {
      print('Failed to focus window: $e');
    }
  }

  static Future<void> showCriticalAlert({
    required String title,
    required String message,
  }) async {
    if (!Platform.isMacOS) return;

    try {
      await showToast(title: title, message: message, isError: true);
      await focusWindow();
    } catch (e) {
      print('Failed to show critical alert: $e');
    }
  }
}
