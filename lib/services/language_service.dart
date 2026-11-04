import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/auth_strings.dart';

/// Remembers the app language (English / French) between launches.
///
/// First launch: follows the phone/PC language (French if it is French,
/// English otherwise). After that, the last choice made on the sign in
/// screen or in Settings > Language.
class LanguageService {
  static const String _key = 'app_language';
  static const List<String> supported = ['en', 'fr'];

  /// Saved language, or the device language on first launch
  static Future<Locale> load() async {
    String? code;
    try {
      final prefs = await SharedPreferences.getInstance();
      code = prefs.getString(_key);
    } catch (_) {}

    if (code == null || !supported.contains(code)) {
      final device = PlatformDispatcher.instance.locale.languageCode;
      code = device == 'fr' ? 'fr' : 'en';
    }
    AuthStrings.code = code;
    return Locale(code);
  }

  static Future<void> save(String code) async {
    if (!supported.contains(code)) return;
    AuthStrings.code = code;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, code);
    } catch (_) {}
  }

  /// Sent with account API calls so the server answers in the same language
  /// (messages and confirmation / reset emails).
  static Map<String, String> get headers => {'Accept-Language': AuthStrings.code};
}
