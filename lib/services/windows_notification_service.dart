import 'dart:io';
import 'package:win_toast/win_toast.dart';
import 'package:window_manager/window_manager.dart';

class WindowsNotificationService {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (!Platform.isWindows) return;

    if (!_initialized) {
      await WinToast.instance().initialize(
        appName: 'Vulcain VPN',
        productName: 'Vulcain VPN',
        companyName: 'Vulcain',
      );
      _initialized = true;
    }
  }

  // ✅ Show toast notification
  static Future<void> showToast({
    required String title,
    required String message,
    bool isError = false,
  }) async {
    if (!Platform.isWindows) return;

    await initialize();

    await WinToast.instance().showToast(
      type: ToastType.text02,
      title: title,
      subtitle: message,
      duration: Duration(seconds: isError ? 10 : 5),
    );
  }

  // ✅ Focus window (bring to foreground)
  static Future<void> focusWindow() async {
    if (!Platform.isWindows) return;

    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
      await Future.delayed(Duration(milliseconds: 500));
      await windowManager.setAlwaysOnTop(false);
    } catch (e) {
      print('Failed to focus window: $e');
    }
  }

  // ✅ Combined: Toast + Window Focus
  static Future<void> showCriticalAlert({
    required String title,
    required String message,
  }) async {
    await showToast(title: title, message: message, isError: true);
    await focusWindow();
  }
}
