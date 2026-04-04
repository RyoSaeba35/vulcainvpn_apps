import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _autoReconnectKey = 'auto_reconnect_enabled';

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
}
