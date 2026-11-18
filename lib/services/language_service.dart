import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/auth_strings.dart';
import '../l10n/languages.dart';

/// Remembers the app language between launches.
///
/// First launch: follows the phone/PC language if the app offers it,
/// English otherwise. After that, the last choice made on the sign in
/// screen or in Settings > Language.
class LanguageService {
  static const String _key = 'app_language';
  static List<String> get supported => appLanguageCodes;

  /// Saved language, or the device language on first launch
  static Future<Locale> load() async {
    String? code;
    try {
      final prefs = await SharedPreferences.getInstance();
      code = prefs.getString(_key);
    } catch (_) {}

    if (code == null || !supported.contains(code)) {
      final device = PlatformDispatcher.instance.locale.languageCode;
      code = supported.contains(device) ? device : 'en';
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
  /// The server only writes English and French, so other languages get English.
  static Map<String, String> get headers =>
      {'Accept-Language': AuthStrings.code == 'fr' ? 'fr' : 'en'};
}
