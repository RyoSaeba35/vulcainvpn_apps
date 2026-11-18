import 'package:flutter/widgets.dart';
import 'translations/auth_en_fr.dart';
import 'translations/nl.dart';
import 'translations/es.dart';
import 'translations/de.dart';
import 'translations/it.dart';
import 'translations/pl.dart';
import 'translations/ja.dart';
import 'translations/ko.dart';
import 'translations/pt.dart';

/// Texts for the account screens (sign in, sign up,
/// forgot password, delete account, Google Play paywall) and the messages
/// the account services produce.
///
/// Screens use `AuthStrings.of(context)`. Services, which have no context,
/// use `AuthStrings.current`, kept in sync with the app language by
/// LanguageService.
class AuthStrings {
  /// Current app language code (one of appLanguages in languages.dart)
  static String code = 'en';

  final String lang;
  const AuthStrings._(this.lang);

  static AuthStrings of(BuildContext context) =>
      AuthStrings._(Localizations.localeOf(context).languageCode);

  static AuthStrings get current => AuthStrings._(code);

  static const Map<String, Map<String, String>> _maps = {
    'en': authEn,
    'fr': authFr,
    'nl': authNl,
    'es': authEs,
    'de': authDe,
    'it': authIt,
    'pl': authPl,
    'ja': authJa,
    'ko': authKo,
    'pt': authPt,
  };

  /// Text for [key] in the current language, English if missing
  String _t(String key) => _maps[lang]?[key] ?? authEn[key] ?? key;

  // ── Language picker ──────────────────────────────────────────────────────
  String get languageLabel => _t('languageLabel');

  // ── Common ───────────────────────────────────────────────────────────────
  String get email => _t('email');
  String get password => _t('password');
  String get or => _t('or');
  String get cancel => _t('cancel');
  String get continueWithGoogle => _t('continueWithGoogle');
  String get terms => _t('terms');
  String get termsOfService => _t('termsOfService');
  String get privacyPolicy => _t('privacyPolicy');
  String get resendConfirmation => _t('resendConfirmation');

  // ── Sign in ──────────────────────────────────────────────────────────────
  String get signInSubtitle => _t('signInSubtitle');
  String get forgotPassword => _t('forgotPassword');
  String get signIn => _t('signIn');
  String get noAccount => _t('noAccount');
  String get createOne => _t('createOne');
  String get enterEmailAndPassword =>
      _t('enterEmailAndPassword');
  String get invalidCredentials => _t('invalidCredentials');
  String get confirmEmailFirst => _t('confirmEmailFirst');
  String get accountLocked => _t('accountLocked');
  String get confirmThenSignIn =>
      _t('confirmThenSignIn');
  String get windowsGoogleHint => _t('windowsGoogleHint');
  String get googleUnavailable => _t('googleUnavailable');
  String get googleFailed =>
      _t('googleFailed');
  String get sessionReset => _t('sessionReset');
  String get confirmingEmail => _t('confirmingEmail');

  // ── New account with Google (confirmation dialog) ────────────────────────
  String get googleNewAccountTitle => _t('googleNewAccountTitle');
  String googleNewAccountBody(String email) => _t('googleNewAccountBody').replaceAll('{email}', '$email');
  String get googleNewAccountTerms => _t('googleNewAccountTerms');
  String get createMyAccount => _t('createMyAccount');

  // ── Sign up ──────────────────────────────────────────────────────────────
  String get createYourAccount => _t('createYourAccount');
  String get oneAccount => _t('oneAccount');
  String passwordMin(int n) => _t('passwordMin').replaceAll('{n}', '$n');
  String get confirmPassword => _t('confirmPassword');
  String get iAccept => _t('iAccept');
  String get andThe => _t('andThe');
  String get createAccount => _t('createAccount');
  String get alreadyHaveAccount =>
      _t('alreadyHaveAccount');
  String get invalidEmail =>
      _t('invalidEmail');
  String passwordTooShort(int n) => _t('passwordTooShort').replaceAll('{n}', '$n');
  String get passwordsDontMatch =>
      _t('passwordsDontMatch');
  String get acceptTerms => _t('acceptTerms');
  String get googleSignUpUnavailable => _t('googleSignUpUnavailable');
  String get checkYourEmail => _t('checkYourEmail');
  String sentConfirmation(String email) => _t('sentConfirmation').replaceAll('{email}', '$email');
  String get goToSignIn => _t('goToSignIn');

  // ── Forgot password ──────────────────────────────────────────────────────
  String get resetTitle => _t('resetTitle');
  String get resetSubtitle => _t('resetSubtitle');
  String get sendResetLink => _t('sendResetLink');
  String resetSent(String email) => _t('resetSent').replaceAll('{email}', '$email');
  String get backToSignIn => _t('backToSignIn');

  // ── Delete account ───────────────────────────────────────────────────────
  String get deleteTitle => _t('deleteTitle');
  String get deleteBullet1 => _t('deleteBullet1');
  String get deleteBullet2 =>
      _t('deleteBullet2');
  String get deleteBullet3 => _t('deleteBullet3');
  String get deletePlayNote => _t('deletePlayNote');
  String get confirmWithPassword => _t('confirmWithPassword');
  String get iUnderstand => _t('iUnderstand');
  String get deletePermanently => _t('deletePermanently');
  String get confirmWithGoogle => _t('confirmWithGoogle');
  String get pleaseConfirmUnderstand => _t('pleaseConfirmUnderstand');
  String get enterPassword => _t('enterPassword');
  String get enterPasswordOrGoogle => _t('enterPasswordOrGoogle');
  String get googleConfirmUnavailable => _t('googleConfirmUnavailable');

  // ── Paywall / Google Play ────────────────────────────────────────────────
  String get premiumSubtitle =>
      _t('premiumSubtitle');
  String get featureUnlimited => _t('featureUnlimited');
  String get featureDevices => _t('featureDevices');
  String get featureNoLogs => _t('featureNoLogs');
  String get featureCancel => _t('featureCancel');
  String get noPlans => _t('noPlans');
  String get subscribe => _t('subscribe');
  String get soldOut => _t('soldOut');
  String get subscriptionsFull => _t('subscriptionsFull');
  String get tryAgain => _t('tryAgain');
  String get restorePurchases => _t('restorePurchases');
  String get checkingPurchases =>
      _t('checkingPurchases');
  String get noPurchaseFound => _t('noPurchaseFound');
  String couldNotOpenPlay(Object e) => _t('couldNotOpenPlay').replaceAll('{e}', '$e');
  String get bestValue => _t('bestValue');
  String get weekly => _t('weekly');
  String get monthly => _t('monthly');
  String get yearly => _t('yearly');
  String get perWeek => _t('perWeek');
  String get perMonth => _t('perMonth');
  String get perYear => _t('perYear');
  String get subscriptionTerms => _t('subscriptionTerms');
  String get playUnavailable =>
      _t('playUnavailable');
  String get couldNotLoadPlans => _t('couldNotLoadPlans');
  String playError(Object e) => _t('playError').replaceAll('{e}', '$e');
  String get signInAgainRetry =>
      _t('signInAgainRetry');
  String get paymentPending => _t('paymentPending');
  String get purchaseFailed =>
      _t('purchaseFailed');
  String get purchaseCancelled => _t('purchaseCancelled');
  String get subscriptionActive => _t('subscriptionActive');
  String get couldNotActivate =>
      _t('couldNotActivate');
  String get purchaseSafe => _t('purchaseSafe');

  // ── Service messages ─────────────────────────────────────────────────────
  String get connectionError =>
      _t('connectionError');
  String get connectionErrorLink => _t('connectionErrorLink');
  String get tooManyAttempts => _t('tooManyAttempts');
  String get invalidLink => _t('invalidLink');
  String get sessionExpired => _t('sessionExpired');
  String get somethingWrong => _t('somethingWrong');
  String get done => _t('done');

  // ── Settings > Support the app ───────────────────────────────────────────
  String get supportTheApp => _t('supportTheApp');
  String get leaveReview => _t('leaveReview');
  String get leaveReviewDesc =>
      _t('leaveReviewDesc');
  String get shareApp => _t('shareApp');
  String get shareAppDesc =>
      _t('shareAppDesc');
  String get supportThanks => _t('supportThanks');
  // Website link first: apps like Facebook keep only the first link and drop
  // the text, and the site has a proper preview (logo, title, description).
  String shareMessage(String playUrl, String siteUrl) => _t('shareMessage').replaceAll('{siteUrl}', '$siteUrl').replaceAll('{playUrl}', '$playUrl');
  String get shareSubject => _t('shareSubject');
  String get couldNotOpenStore =>
      _t('couldNotOpenStore');
}
