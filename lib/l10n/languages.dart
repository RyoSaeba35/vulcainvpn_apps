/// Languages offered in the app (sign in picker, Settings > Language).
/// Names are written in their own language so anyone can find theirs.
class AppLanguage {
  final String code;
  final String flag;
  final String name;
  const AppLanguage(this.code, this.flag, this.name);
}

const List<AppLanguage> appLanguages = [
  AppLanguage('en', '🇬🇧', 'English'),
  AppLanguage('fr', '🇫🇷', 'Français'),
  AppLanguage('de', '🇩🇪', 'Deutsch'),
  AppLanguage('es', '🇪🇸', 'Español'),
  AppLanguage('it', '🇮🇹', 'Italiano'),
  AppLanguage('nl', '🇳🇱', 'Nederlands'),
  AppLanguage('pl', '🇵🇱', 'Polski'),
  AppLanguage('pt', '🇧🇷', 'Português'),
  AppLanguage('ja', '🇯🇵', '日本語'),
  AppLanguage('ko', '🇰🇷', '한국어'),
];

final List<String> appLanguageCodes = [for (final l in appLanguages) l.code];

/// Language for [code], English if the code is not offered
AppLanguage appLanguageFor(String code) =>
    appLanguages.firstWhere((l) => l.code == code, orElse: () => appLanguages.first);
