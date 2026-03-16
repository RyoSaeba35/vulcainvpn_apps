import 'dart:io';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayWindowService with TrayListener, WindowListener {
  final Function() onToggleConnection;
  final Function() onQuit;

  static const _channel = BasicMessageChannel<String>(
    'vulcain_vpn/window',
    StringCodec(),
  );

  TrayWindowService({
    required this.onToggleConnection,
    required this.onQuit,
  });

  Future<void> init() async {
    if (!Platform.isWindows) return;
    trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    // Listen for show signal from second instance
    _channel.setMessageHandler((message) async {
      if (message == 'show') {
        await windowManager.show();
        await windowManager.focus();
      }
      return '';
    });

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final iconPath = '$exeDir\\data\\flutter_assets\\assets\\icon\\icon.ico';
    await trayManager.setIcon(iconPath);
    await updateState(false);
  }

  void dispose() {
    if (!Platform.isWindows) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
  }

  Future<void> updateState(bool connected) async {
    if (!Platform.isWindows) return;
    final menu = Menu(items: [
      MenuItem(key: 'show', label: 'Open Vulcain VPN'),
      MenuItem.separator(),
      MenuItem(
        key: 'toggle',
        label: connected ? 'Disconnect' : 'Connect',
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]);
    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip(
      connected ? 'Vulcain VPN — Connected' : 'Vulcain VPN — Disconnected',
    );
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'toggle') {
      onToggleConnection();
    } else if (menuItem.key == 'quit') {
      onQuit();
    }
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}
