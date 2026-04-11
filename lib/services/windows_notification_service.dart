import 'dart:io';
import 'package:win_toast/win_toast.dart';
import 'package:window_manager/window_manager.dart';

class WindowsNotificationService {
  static bool _initialized = false;

  /// Initialize the Windows notification service
  static Future<void> initialize() async {
    if (!Platform.isWindows) return;

    if (!_initialized) {
      try {
        await WinToast.instance().initialize(
          appName: 'Vulcain VPN',
          productName: 'Vulcain VPN',
          companyName: 'Vulcain',
        );
        _initialized = true;
      } catch (e) {
        print('Failed to initialize Windows notifications: $e');
      }
    }
  }

  /// Show a toast notification
  static Future<void> showToast({
    required String title,
    required String message,
    bool isError = false,
  }) async {
    if (!Platform.isWindows) return;

    try {
      await initialize();

      await WinToast.instance().showToast(
        type: ToastType.text02,
        title: title,
        subtitle: message,
      );
    } catch (e) {
      print('Failed to show toast notification: $e');
    }
  }

  /// Focus the application window
  static Future<void> focusWindow() async {
    if (!Platform.isWindows) return;

    try {
      await windowManager.show();
      await windowManager.focus();

      // Temporarily set always on top to ensure visibility
      await windowManager.setAlwaysOnTop(true);
      await Future.delayed(Duration(milliseconds: 500));
      await windowManager.setAlwaysOnTop(false);
    } catch (e) {
      print('Failed to focus window: $e');
    }
  }

  /// Show critical alert (toast + bring window to foreground)
  static Future<void> showCriticalAlert({
    required String title,
    required String message,
  }) async {
    if (!Platform.isWindows) return;

    try {
      // Show toast notification
      await showToast(
        title: title,
        message: message,
        isError: true,
      );

      // Bring window to foreground
      await focusWindow();
    } catch (e) {
      print('Failed to show critical alert: $e');
    }
  }
}
