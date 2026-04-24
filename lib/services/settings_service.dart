import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionMode {
  standard,  // WireGuard → Hysteria2 → SS (speed priority)
  stealth,   // SS → Hysteria2 only (China/restrictive networks)
  balanced,  // SS → Hysteria2 → WireGuard (smart selection)
}


class SettingsService {
  static const String _autoReconnectKey = 'auto_reconnect_enabled';
  static const String _connectionModeKey = 'connection_mode';

  // Get auto-reconnect setting
  static Future<bool> getAutoReconnect() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoReconnectKey) ?? true; // Default: enabled
  }

  // Set auto-reconnect setting
  static Future<void> setAutoReconnect(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoReconnectKey, enabled);
  }

  static Future<ConnectionMode> getConnectionMode() async {
    final prefs = await SharedPreferences.getInstance();
    final modeString = prefs.getString(_connectionModeKey) ?? 'balanced';
    return ConnectionMode.values.firstWhere(
      (e) => e.name == modeString,
      orElse: () => ConnectionMode.balanced,
    );
  }

  static Future<void> setConnectionMode(ConnectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_connectionModeKey, mode.name);
  }
}
