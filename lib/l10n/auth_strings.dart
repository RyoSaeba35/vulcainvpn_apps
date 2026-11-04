import 'package:flutter/widgets.dart';

/// English / French texts for the account screens (sign in, sign up,
/// forgot password, delete account, Google Play paywall) and the messages
/// the account services produce.
///
/// Screens use `AuthStrings.of(context)`. Services, which have no context,
/// use `AuthStrings.current`, kept in sync with the app language by
/// LanguageService.
class AuthStrings {
  /// Current app language code ('en' or 'fr')
  static String code = 'en';

  final bool fr;
  const AuthStrings._(this.fr);

  static AuthStrings of(BuildContext context) =>
      AuthStrings._(Localizations.localeOf(context).languageCode == 'fr');

  static AuthStrings get current => AuthStrings._(code == 'fr');

  String _t(String en, String fr) => this.fr ? fr : en;

  // ── Language picker ──────────────────────────────────────────────────────
  String get languageLabel => _t('Language', 'Langue');

  // ── Common ───────────────────────────────────────────────────────────────
  String get email => _t('Email', 'Email');
  String get password => _t('Password', 'Mot de passe');
  String get or => _t('or', 'ou');
  String get cancel => _t('Cancel', 'Annuler');
  String get continueWithGoogle => _t('Continue with Google', 'Continuer avec Google');
  String get terms => _t('Terms', 'Conditions');
  String get termsOfService => _t('Terms of Service', "Conditions d'utilisation");
  String get privacyPolicy => _t('Privacy Policy', 'Politique de confidentialité');
  String get resendConfirmation => _t('Resend confirmation email', "Renvoyer l'email de confirmation");

  // ── Sign in ──────────────────────────────────────────────────────────────
  String get signInSubtitle => _t('Sign in to your account', 'Connectez-vous à votre compte');
  String get forgotPassword => _t('Forgot password?', 'Mot de passe oublié ?');
  String get signIn => _t('Sign In', 'Se connecter');
  String get noAccount => _t("Don't have an account? ", 'Pas encore de compte ? ');
  String get createOne => _t('Create one', 'Créer un compte');
  String get enterEmailAndPassword =>
      _t('Please enter your email and password.', 'Saisissez votre email et votre mot de passe.');
  String get invalidCredentials => _t('Invalid email or password.', 'Email ou mot de passe incorrect.');
  String get confirmEmailFirst => _t(
      'Please confirm your email first. Check your inbox (and spam folder).',
      "Confirmez d'abord votre email. Vérifiez votre boîte de réception (et vos spams).");
  String get accountLocked => _t(
      'Account is locked after too many failed attempts. Check your email or try again in 1 hour.',
      'Compte bloqué après trop de tentatives. Consultez vos emails ou réessayez dans 1 heure.');
  String get confirmThenSignIn =>
      _t('Confirm your email, then sign in here.', 'Confirmez votre email, puis connectez-vous ici.');
  String get windowsGoogleHint => _t(
      'Signed up with Google? Use "Forgot password?" once to set a password for this app.',
      'Inscrit avec Google ? Utilisez « Mot de passe oublié ? » une fois pour définir un mot de passe pour cette application.');
  String get googleUnavailable => _t(
      'Google sign-in is not available right now. Use your email and password.',
      "La connexion avec Google n'est pas disponible pour le moment. Utilisez votre email et votre mot de passe.");
  String get googleFailed =>
      _t('Google sign-in failed. Please try again.', 'La connexion avec Google a échoué. Réessayez.');
  String get sessionReset => _t(
      'Your session was reset automatically (security key changed). '
          'This can happen after an OS update or device restore. Please log in again.',
      'Votre session a été réinitialisée automatiquement (clé de sécurité modifiée). '
          "Cela peut arriver après une mise à jour du système ou une restauration de l'appareil. "
          'Veuillez vous reconnecter.');
  String get confirmingEmail => _t('Confirming your email...', 'Confirmation de votre email...');

  // ── New account with Google (confirmation dialog) ────────────────────────
  String get googleNewAccountTitle => _t('Create a Vulcain account?', 'Créer un compte Vulcain ?');
  String googleNewAccountBody(String email) => _t(
      'There is no Vulcain account for $email.\n\n'
          'If you had an account with this address and deleted it, it is not restored: '
          'a new, empty account will be created.',
      "Aucun compte Vulcain n'existe pour $email.\n\n"
          "Si vous aviez un compte avec cette adresse et l'avez supprimé, il n'est pas restauré : "
          'un nouveau compte vide sera créé.');
  String get googleNewAccountTerms => _t(
      'By creating an account, you agree to our Terms of Service and Privacy Policy.',
      "En créant un compte, vous acceptez nos Conditions d'utilisation et notre Politique de confidentialité.");
  String get createMyAccount => _t('Create my account', 'Créer mon compte');

  // ── Sign up ──────────────────────────────────────────────────────────────
  String get createYourAccount => _t('Create your account', 'Créez votre compte');
  String get oneAccount => _t('One account for all your devices', 'Un seul compte pour tous vos appareils');
  String passwordMin(int n) => _t('Password (min. $n characters)', 'Mot de passe (min. $n caractères)');
  String get confirmPassword => _t('Confirm password', 'Confirmer le mot de passe');
  String get iAccept => _t('I accept the ', "J'accepte les ");
  String get andThe => _t(' and the ', ' et la ');
  String get createAccount => _t('Create account', 'Créer le compte');
  String get alreadyHaveAccount =>
      _t('Already have an account? Sign in', 'Déjà un compte ? Se connecter');
  String get invalidEmail =>
      _t('Please enter a valid email address.', 'Saisissez une adresse email valide.');
  String passwordTooShort(int n) => _t(
      'Password must be at least $n characters.', 'Le mot de passe doit contenir au moins $n caractères.');
  String get passwordsDontMatch =>
      _t('Passwords do not match.', 'Les mots de passe ne correspondent pas.');
  String get acceptTerms => _t('Please accept the Terms of Service and Privacy Policy.',
      "Acceptez les Conditions d'utilisation et la Politique de confidentialité.");
  String get googleSignUpUnavailable => _t(
      'Google sign-up is not available right now. Use your email instead.',
      "L'inscription avec Google n'est pas disponible pour le moment. Utilisez votre email.");
  String get checkYourEmail => _t('Check your email', 'Vérifiez vos emails');
  String sentConfirmation(String email) => _t(
      'We sent a confirmation link to\n$email\n\n'
          "Open it to activate your account, then come back and sign in. "
          "Check your spam folder if you don't see it.",
      'Nous avons envoyé un lien de confirmation à\n$email\n\n'
          'Ouvrez-le pour activer votre compte, puis revenez vous connecter. '
          'Pensez à vérifier vos spams.');
  String get goToSignIn => _t('Go to sign in', 'Aller à la connexion');

  // ── Forgot password ──────────────────────────────────────────────────────
  String get resetTitle => _t('Reset your password', 'Réinitialiser le mot de passe');
  String get resetSubtitle => _t(
      'Enter your account email. We will send you a link to choose a new password.',
      'Saisissez l\'email de votre compte. Nous vous enverrons un lien pour choisir un nouveau mot de passe.');
  String get sendResetLink => _t('Send reset link', 'Envoyer le lien');
  String resetSent(String email) => _t(
      'If an account exists for $email, you will receive a link to choose a new password. '
          "Check your spam folder if you don't see it.\n\n"
          'Then come back here and sign in with your new password.',
      'Si un compte existe pour $email, vous recevrez un lien pour choisir un nouveau mot de passe. '
          'Pensez à vérifier vos spams.\n\n'
          'Revenez ensuite ici et connectez-vous avec votre nouveau mot de passe.');
  String get backToSignIn => _t('Back to sign in', 'Retour à la connexion');

  // ── Delete account ───────────────────────────────────────────────────────
  String get deleteTitle => _t('Delete your account', 'Supprimer votre compte');
  String get deleteBullet1 => _t('Your account, devices and connection history are permanently deleted.',
      'Votre compte, vos appareils et votre historique de connexion sont supprimés définitivement.');
  String get deleteBullet2 =>
      _t('Any remaining subscription time is lost.', "Le temps d'abonnement restant est perdu.");
  String get deleteBullet3 => _t('This cannot be undone.', 'Cette action est irréversible.');
  String get deletePlayNote => _t(
      'A subscription bought on Google Play must also be cancelled in Google Play > Payments & subscriptions.',
      'Un abonnement souscrit sur Google Play doit aussi être résilié dans Google Play > Paiements et abonnements.');
  String get confirmWithPassword => _t('Confirm with your password', 'Confirmez avec votre mot de passe');
  String get iUnderstand => _t('I understand my account will be deleted permanently',
      'Je comprends que mon compte sera supprimé définitivement');
  String get deletePermanently => _t('Delete permanently', 'Supprimer définitivement');
  String get confirmWithGoogle => _t('Signed up with Google? Confirm with Google instead',
      'Inscrit avec Google ? Confirmez plutôt avec Google');
  String get pleaseConfirmUnderstand => _t('Please confirm you understand this cannot be undone.',
      'Confirmez que vous comprenez que cette action est irréversible.');
  String get enterPassword => _t('Please enter your password.', 'Saisissez votre mot de passe.');
  String get enterPasswordOrGoogle => _t(
      'Enter your password, or use "Confirm with Google" below if you signed up with Google.',
      'Saisissez votre mot de passe, ou utilisez « Confirmez avec Google » ci-dessous si vous vous êtes inscrit avec Google.');
  String get googleConfirmUnavailable => _t('Google confirmation is not available right now.',
      "La confirmation avec Google n'est pas disponible pour le moment.");

  // ── Paywall / Google Play ────────────────────────────────────────────────
  String get premiumSubtitle =>
      _t('Fast, private and secure on all your devices', 'Rapide, privé et sécurisé sur tous vos appareils');
  String get featureUnlimited => _t('Unlimited secure VPN connection', 'Connexion VPN sécurisée illimitée');
  String get featureDevices => _t('Up to 3 devices at the same time (Android and Windows)',
      "Jusqu'à 3 appareils en même temps (Android et Windows)");
  String get featureNoLogs => _t('No browsing logs', 'Aucun historique de navigation');
  String get featureCancel => _t('Cancel anytime in Google Play', 'Résiliable à tout moment dans Google Play');
  String get noPlans => _t('No subscription is available right now. Please try again later.',
      "Aucun abonnement n'est disponible pour le moment. Réessayez plus tard.");
  String get subscribe => _t('Subscribe', "S'abonner");
  String get soldOut => _t('Sold out', 'Complet');
  String get subscriptionsFull => _t(
      "We're at capacity right now, so new subscriptions are paused. Check back in a few minutes!",
      'Nous sommes à pleine capacité en ce moment : les nouveaux abonnements sont en pause. Revenez dans quelques minutes !');
  String get tryAgain => _t('Try again', 'Réessayer');
  String get restorePurchases => _t('Restore purchases', 'Restaurer les achats');
  String get checkingPurchases =>
      _t('Checking your Google Play purchases...', 'Vérification de vos achats Google Play...');
  String get noPurchaseFound => _t('No active Google Play subscription found for this account.',
      'Aucun abonnement Google Play actif trouvé pour ce compte.');
  String couldNotOpenPlay(Object e) => _t('Could not open Google Play: $e', "Impossible d'ouvrir Google Play : $e");
  String get bestValue => _t('Best value', 'Meilleure offre');
  String get weekly => _t('Weekly', 'Hebdomadaire');
  String get monthly => _t('Monthly', 'Mensuel');
  String get yearly => _t('Yearly', 'Annuel');
  String get perWeek => _t('/ week', '/ semaine');
  String get perMonth => _t('/ month', '/ mois');
  String get perYear => _t('/ year', '/ an');
  String get subscriptionTerms => _t(
      'Payment is charged to your Google Play account. The subscription renews automatically at the same '
          'price for the same period unless you cancel it at least 24 hours before the end of the current '
          'period. Manage or cancel anytime in Google Play > Payments & subscriptions.',
      "Le paiement est débité sur votre compte Google Play. L'abonnement est renouvelé automatiquement au "
          'même prix et pour la même durée, sauf résiliation au moins 24 heures avant la fin de la période en '
          'cours. Gérez-le ou résiliez-le à tout moment dans Google Play > Paiements et abonnements.');
  String get playUnavailable =>
      _t('Google Play is not available on this device.', "Google Play n'est pas disponible sur cet appareil.");
  String get couldNotLoadPlans => _t('Could not load subscription options. Check your connection.',
      "Impossible de charger les offres. Vérifiez votre connexion.");
  String playError(Object e) => _t('Google Play error: $e', 'Erreur Google Play : $e');
  String get signInAgainRetry =>
      _t('Please sign in again, then retry.', 'Reconnectez-vous, puis réessayez.');
  String get paymentPending => _t(
      'Payment pending. Your subscription starts as soon as Google Play confirms it.',
      'Paiement en attente. Votre abonnement démarre dès que Google Play le confirme.');
  String get purchaseFailed =>
      _t('The purchase could not be completed.', "L'achat n'a pas pu être finalisé.");
  String get purchaseCancelled => _t('Purchase cancelled.', 'Achat annulé.');
  String get subscriptionActive => _t('Subscription active. Thank you!', 'Abonnement actif. Merci !');
  String get couldNotActivate =>
      _t('Could not activate the subscription.', "Impossible d'activer l'abonnement.");
  String get purchaseSafe => _t(
      'Connection error. Your purchase is safe: tap "Restore purchases" once you are online.',
      'Erreur de connexion. Votre achat est conservé : touchez « Restaurer les achats » une fois en ligne.');

  // ── Service messages ─────────────────────────────────────────────────────
  String get connectionError =>
      _t('Connection error. Check your internet and try again.', 'Erreur de connexion. Vérifiez votre connexion internet et réessayez.');
  String get connectionErrorLink => _t('Connection error. Check your internet and open the link again.',
      'Erreur de connexion. Vérifiez votre connexion internet et rouvrez le lien.');
  String get tooManyAttempts => _t('Too many attempts. Please wait a moment and try again.',
      'Trop de tentatives. Patientez un instant et réessayez.');
  String get invalidLink => _t('This confirmation link is invalid.', 'Ce lien de confirmation est invalide.');
  String get sessionExpired => _t('Your session has expired. Please sign in again, then retry.',
      'Votre session a expiré. Reconnectez-vous, puis réessayez.');
  String get somethingWrong => _t('Something went wrong. Please try again.', 'Une erreur est survenue. Réessayez.');
  String get done => _t('Done.', 'Terminé.');

  // ── Settings > Support the app ───────────────────────────────────────────
  String get supportTheApp => _t('Support the app', "Soutenir l'application");
  String get leaveReview => _t('Leave a review', 'Laisser un avis');
  String get leaveReviewDesc =>
      _t('Rate Vulcain VPN on Google Play', 'Notez Vulcain VPN sur Google Play');
  String get shareApp => _t('Share the app', "Partager l'application");
  String get shareAppDesc =>
      _t('Recommend Vulcain VPN to a friend', 'Recommandez Vulcain VPN à un ami');
  String get supportThanks => _t(
      'Vulcain VPN is made by an independent developer. A review or a share really helps!',
      'Vulcain VPN est développé par un développeur indépendant. Un avis ou un partage aide vraiment !');
  String shareMessage(String playUrl, String siteUrl) => _t(
      'I use Vulcain VPN, a fast and private VPN.\n'
          'Android: $playUrl\n'
          'Windows and more: $siteUrl',
      "J'utilise Vulcain VPN, un VPN rapide et respectueux de la vie privée.\n"
          'Android : $playUrl\n'
          'Windows et plus : $siteUrl');
  String get shareSubject => _t('Try Vulcain VPN', 'Essaie Vulcain VPN');
  String get couldNotOpenStore =>
      _t('Could not open Google Play.', "Impossible d'ouvrir Google Play.");
}
