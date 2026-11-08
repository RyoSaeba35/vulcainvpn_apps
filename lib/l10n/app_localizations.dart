import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final Map<String, Map<String, String>> _localizedValues = {
    'en': {
      // App general
      'app_title': 'Vulcain VPN',

      // Connection states
      'connected': 'Connected',
      'disconnected': 'Disconnected',
      'connecting': 'Connecting...',
      'disconnecting': 'Disconnecting...',

      // Home tab
      'location': 'Location',
      'ip': 'IP',
      "country": "Country",
      'duration': 'Duration',
      'secure_connection': '🔒 Your connection is secure',
      'disconnect': 'Disconnect',
      'connect': 'Connect',
      'connecting_btn': 'Connecting...',
      'disconnecting_btn': 'Disconnecting...',
      'fetching_ip': 'Fetching IP...',

      // Error dialogs - Admin
      'admin_required_title': 'Admin Rights Required',
      'admin_required_message': 'Managing VPN tunnels on Windows requires administrator privileges. Please restart the app as administrator.',

      // Error dialogs - Connection
      'connection_failed_title': 'Connection Failed',
      'connection_failed_message': 'Failed to start VPN. Please check permissions.',
      'connection_error_title': 'Connection Error',

      // Error dialogs - Subscription
      'subscription_required_title': 'Subscription Required',
      'subscription_expired_message': 'Your VPN subscription has expired.\n\nPlease renew your subscription to continue using the VPN.',
      'renew_now': 'Renew Now',

      // Error dialogs - Device limit
      'device_limit_title': 'Device Limit Reached',
      'device_limit_message': 'You can only connect 3 devices at the same time.\n\nPlease disconnect another device and try again.',
      'device_limit_429_message': 'Maximum number of active connections reached.\n\nPlease disconnect another device first.',

      // Error dialogs - Registration
      'not_registered_title': 'Not Registered',
      'not_registered_message': 'Your device is not registered. Please logout and login again.',

      // Error dialogs - Permissions
      'permission_required_title': 'Permission Required',
      'notification_permission_message': 'Notification permission is required for the VPN to stay active.\n\nPlease allow it and try again.',
      'vpn_permission_message': 'VPN permission is required to protect your connection.\n\nPlease allow it and try again.',

      // General buttons
      'ok': 'OK',
      'cancel': 'Cancel',
      'close': 'Close',
      'retry': 'Retry',

      // Bottom navigation
      'nav_home': 'Home',
      'nav_subscription': 'Subscription',
      'nav_settings': 'Settings',

      // Subscription tab
      'subscription': 'Subscription',
      'plan': 'Plan',
      'reference': 'Reference',
      'status': 'Status',
      'expires': 'Expires',
      'days_remaining': 'Days remaining',
      'days_suffix': 'days',
      'server': 'Server',
      'devices': 'Devices',
      'active_connections': 'Active connections',
      'failed_load_subscription': 'Failed to load subscription info.',
      'no_subscription_data': 'No subscription data available.',

      // Settings tab
      'account': 'Account',
      'email': 'Email',
      'preferences': 'Preferences',
      'language': 'Language',
      'english': 'English',
      'french': 'French',

      // Settings - Connection Mode
      'connection_mode': 'Connection Mode',
      'mode_standard': 'Standard',
      'mode_standard_desc': 'Maximum speed',
      'mode_standard_full': 'Standard (fastest)',
      'mode_stealth': 'Stealth',
      'mode_stealth_desc': 'For restrictive networks',
      'mode_stealth_full': 'Stealth (restrictive networks)',
      'mode_balanced': 'Balanced',
      'mode_balanced_desc': 'Smart selection for any network',
      'mode_balanced_full': 'Balanced (recommended)',
      'mode_changed': 'Connection mode: {mode}',
      'mode_reconnect_hint': 'Reconnect VPN to apply changes',

      // Settings - Auto Reconnect
      'auto_reconnect': 'Auto-Reconnect',
      'auto_reconnect_desc': 'Automatically reconnect if VPN connection is lost',
      'auto_reconnect_enabled': 'Auto-reconnect enabled',
      'auto_reconnect_disabled': 'Auto-reconnect disabled',

      // Debug
      'debug': 'Debug',
      'debug_info': 'Debug Info',
      'show': 'Show',
      'not_logged_in': 'Not logged in',
      'not_registered': 'Not registered',
      'missing': 'Missing',
      'last_vpn_config': 'Last VPN Config:',
      'no_config_yet': 'No config built yet. Try connecting first.',
      'full_config': 'Full Config',
      'view_full_config': 'View Full Config',
      'error': 'Error',
      'failed_load_debug': 'Failed to load debug info:',
      'device_id': 'Device ID',
      'api_key': 'API Key',

      // Logout
      'logout': 'Logout',
      'logout_confirmation': 'Are you sure you want to logout?',

      // VPN locations
      'choose_location_title': 'Choose your VPN location',
      'choose_location_subtitle': 'Select a country or let Vulcain choose for you.',
      'location_automatic': 'Automatic',
      'location_automatic_desc': 'Best server for your connection',
      'location_recommended': 'Recommended',
      'location_coming_soon': 'Coming soon',
      'location_maintenance': 'Temporarily unavailable',
      'location_full': 'Full right now',
      'location_unavailable': 'Unavailable',
      'location_list_error': 'Could not load the latest locations. Showing the last known list.',
      'location_unavailable_title': 'Location unavailable',
      'location_use_automatic': 'Use Automatic',
      'location_choose_another': 'Choose another',
      'location_switching': 'Switching location...',
      'location_connected_via': 'Server',
      'region_europe': 'Europe',
      'region_americas': 'Americas',
      'region_asia_pacific': 'Asia-Pacific',
      'region_middle_east': 'Middle East',
      'region_africa': 'Africa',
      'region_oceania': 'Oceania',

      // Free access
      'free_trial': 'Free trial',
      'free_gift': 'Free access (gift)',
      'free_access_until': 'Free access until',
      'subscribe_to_keep': 'Subscribe to keep VulcainVPN after this date.',
      'subscribe_now': 'Subscribe',
      'trial_started_title': 'Your free trial has started 🎁',
      'trial_started_message': 'Enjoy VulcainVPN free for {days} days, until {date}. No payment needed. We also sent you an email.',
    },
    'fr': {
      // App general
      'app_title': 'Vulcain VPN',

      // Connection states
      'connected': 'Connecté',
      'disconnected': 'Déconnecté',
      'connecting': 'Connexion en cours...',
      'disconnecting': 'Déconnexion en cours...',

      // Home tab
      'location': 'Localisation',
      'ip': 'IP',
      'country': 'Pays',
      'duration': 'Durée',
      'secure_connection': '🔒 Votre connexion est sécurisée',
      'disconnect': 'Déconnecter',
      'connect': 'Connecter',
      'connecting_btn': 'Connexion...',
      'disconnecting_btn': 'Déconnexion...',
      'fetching_ip': 'Récupération IP...',

      // Error dialogs - Admin
      'admin_required_title': 'Droits Administrateur Requis',
      'admin_required_message': 'La gestion des tunnels VPN sur Windows nécessite des privilèges d\'administrateur. Veuillez redémarrer l\'application en tant qu\'administrateur.',

      // Error dialogs - Connection
      'connection_failed_title': 'Échec de Connexion',
      'connection_failed_message': 'Impossible de démarrer le VPN. Veuillez vérifier les permissions.',
      'connection_error_title': 'Erreur de Connexion',

      // Error dialogs - Subscription
      'subscription_required_title': 'Abonnement Requis',
      'subscription_expired_message': 'Votre abonnement VPN a expiré.\n\nVeuillez renouveler votre abonnement pour continuer à utiliser le VPN.',
      'renew_now': 'Renouveler Maintenant',

      // Error dialogs - Device limit
      'device_limit_title': 'Limite d\'Appareils Atteinte',
      'device_limit_message': 'Vous ne pouvez connecter que 3 appareils en même temps.\n\nVeuillez déconnecter un autre appareil et réessayer.',
      'device_limit_429_message': 'Nombre maximum de connexions actives atteint.\n\nVeuillez d\'abord déconnecter un autre appareil.',

      // Error dialogs - Registration
      'not_registered_title': 'Non Enregistré',
      'not_registered_message': 'Votre appareil n\'est pas enregistré. Veuillez vous déconnecter et vous reconnecter.',

      // Error dialogs - Permissions
      'permission_required_title': 'Permission Requise',
      'notification_permission_message': 'La permission de notification est requise pour que le VPN reste actif.\n\nVeuillez l\'autoriser et réessayer.',
      'vpn_permission_message': 'La permission VPN est requise pour protéger votre connexion.\n\nVeuillez l\'autoriser et réessayer.',

      // General buttons
      'ok': 'OK',
      'cancel': 'Annuler',
      'close': 'Fermer',
      'retry': 'Réessayer',

      // Bottom navigation
      'nav_home': 'Accueil',
      'nav_subscription': 'Abonnement',
      'nav_settings': 'Paramètres',

      // Subscription tab
      'subscription': 'Abonnement',
      'plan': 'Forfait',
      'reference': 'Référence',
      'status': 'Statut',
      'expires': 'Expire',
      'days_remaining': 'Jours restants',
      'days_suffix': 'jours',
      'server': 'Serveur',
      'devices': 'Appareils',
      'active_connections': 'Connexions actives',
      'failed_load_subscription': 'Échec du chargement des informations d\'abonnement.',
      'no_subscription_data': 'Aucune donnée d\'abonnement disponible.',

      // Settings tab
      'account': 'Compte',
      'email': 'Email',
      'preferences': 'Préférences',
      'language': 'Langue',
      'english': 'Anglais',
      'french': 'Français',

      // Settings - Connection Mode
      'connection_mode': 'Mode de Connexion',
      'mode_standard': 'Standard',
      'mode_standard_desc': 'Vitesse maximale',
      'mode_standard_full': 'Standard (le plus rapide)',
      'mode_stealth': 'Furtif',
      'mode_stealth_desc': 'Pour réseaux restrictifs',
      'mode_stealth_full': 'Furtif (réseaux restrictifs)',
      'mode_balanced': 'Équilibré',
      'mode_balanced_desc': 'Sélection intelligente pour tout réseau',
      'mode_balanced_full': 'Équilibré (recommandé)',
      'mode_changed': 'Mode de connexion : {mode}',
      'mode_reconnect_hint': 'Reconnectez le VPN pour appliquer les changements',

      // Settings - Auto Reconnect
      'auto_reconnect': 'Reconnexion Automatique',
      'auto_reconnect_desc': 'Se reconnecter automatiquement si la connexion VPN est perdue',
      'auto_reconnect_enabled': 'Reconnexion automatique activée',
      'auto_reconnect_disabled': 'Reconnexion automatique désactivée',

      // Debug
      'debug': 'Débogage',
      'debug_info': 'Infos de Débogage',
      'show': 'Afficher',
      'not_logged_in': 'Non connecté',
      'not_registered': 'Non enregistré',
      'missing': 'Manquant',
      'last_vpn_config': 'Dernière Config VPN:',
      'no_config_yet': 'Aucune config construite. Essayez de vous connecter d\'abord.',
      'full_config': 'Config Complète',
      'view_full_config': 'Voir la Config Complète',
      'error': 'Erreur',
      'failed_load_debug': 'Échec du chargement des infos de débogage:',
      'device_id': 'ID de l\'Appareil',
      'api_key': 'Clé API',

      // Logout
      'logout': 'Déconnexion',
      'logout_confirmation': 'Êtes-vous sûr de vouloir vous déconnecter?',

      // VPN locations
      'choose_location_title': 'Choisissez votre localisation VPN',
      'choose_location_subtitle': 'Sélectionnez un pays ou laissez Vulcain choisir pour vous.',
      'location_automatic': 'Automatique',
      'location_automatic_desc': 'Le meilleur serveur pour votre connexion',
      'location_recommended': 'Recommandé',
      'location_coming_soon': 'Bientôt disponible',
      'location_maintenance': 'Temporairement indisponible',
      'location_full': 'Complet pour le moment',
      'location_unavailable': 'Indisponible',
      'location_list_error': 'Impossible de charger les localisations. Affichage de la dernière liste connue.',
      'location_unavailable_title': 'Localisation indisponible',
      'location_use_automatic': 'Utiliser Automatique',
      'location_choose_another': 'En choisir une autre',
      'location_switching': 'Changement de localisation...',
      'location_connected_via': 'Serveur',
      'region_europe': 'Europe',
      'region_americas': 'Amériques',
      'region_asia_pacific': 'Asie-Pacifique',
      'region_middle_east': 'Moyen-Orient',
      'region_africa': 'Afrique',
      'region_oceania': 'Océanie',

      // Free access
      'free_trial': 'Essai gratuit',
      'free_gift': 'Accès offert',
      'free_access_until': 'Accès gratuit jusqu\'au',
      'subscribe_to_keep': 'Abonnez-vous pour garder VulcainVPN après cette date.',
      'subscribe_now': 'S\'abonner',
      'trial_started_title': 'Votre essai gratuit a commencé 🎁',
      'trial_started_message': 'Profitez de VulcainVPN gratuitement pendant {days} jours, jusqu\'au {date}. Aucun paiement nécessaire. Nous vous avons aussi envoyé un e-mail.',
    },
  };

  String translate(String key) {
    return _localizedValues[locale.languageCode]?[key] ?? key;
  }

  // Convenience getters - General
  String get appTitle => translate('app_title');

  // Connection states
  String get connected => translate('connected');
  String get disconnected => translate('disconnected');
  String get connecting => translate('connecting');
  String get disconnecting => translate('disconnecting');

  // Home tab
  String get location => translate('location');
  String get ip => translate('ip');
  String get country => translate('country');
  String get duration => translate('duration');
  String get secureConnection => translate('secure_connection');
  String get disconnect => translate('disconnect');
  String get connect => translate('connect');
  String get connectingBtn => translate('connecting_btn');
  String get disconnectingBtn => translate('disconnecting_btn');
  String get fetchingIp => translate('fetching_ip');

  // Error dialogs - Admin
  String get adminRequiredTitle => translate('admin_required_title');
  String get adminRequiredMessage => translate('admin_required_message');

  // Error dialogs - Connection
  String get connectionFailedTitle => translate('connection_failed_title');
  String get connectionFailedMessage => translate('connection_failed_message');
  String get connectionErrorTitle => translate('connection_error_title');

  // Error dialogs - Subscription
  String get subscriptionRequiredTitle => translate('subscription_required_title');
  String get subscriptionExpiredMessage => translate('subscription_expired_message');
  String get renewNow => translate('renew_now');

  // Error dialogs - Device limit
  String get deviceLimitTitle => translate('device_limit_title');
  String get deviceLimitMessage => translate('device_limit_message');
  String get deviceLimit429Message => translate('device_limit_429_message');

  // Error dialogs - Registration
  String get notRegisteredTitle => translate('not_registered_title');
  String get notRegisteredMessage => translate('not_registered_message');

  // Error dialogs - Permissions
  String get permissionRequiredTitle => translate('permission_required_title');
  String get notificationPermissionMessage => translate('notification_permission_message');
  String get vpnPermissionMessage => translate('vpn_permission_message');

  // General buttons
  String get ok => translate('ok');
  String get cancel => translate('cancel');
  String get close => translate('close');
  String get retry => translate('retry');

  // Bottom navigation
  String get navHome => translate('nav_home');
  String get navSubscription => translate('nav_subscription');
  String get navSettings => translate('nav_settings');

  // Subscription tab
  String get subscription => translate('subscription');
  String get plan => translate('plan');
  String get reference => translate('reference');
  String get status => translate('status');
  String get expires => translate('expires');
  String get daysRemaining => translate('days_remaining');
  String get daysSuffix => translate('days_suffix');
  String get server => translate('server');
  String get devices => translate('devices');
  String get activeConnections => translate('active_connections');
  String get failedLoadSubscription => translate('failed_load_subscription');
  String get noSubscriptionData => translate('no_subscription_data');

  // Settings tab
  String get account => translate('account');
  String get email => translate('email');
  String get preferences => translate('preferences');
  String get language => translate('language');
  String get english => translate('english');
  String get french => translate('french');

  // Settings - Connection Mode
  String get connectionMode => translate('connection_mode');
  String get modeStandard => translate('mode_standard');
  String get modeStandardDesc => translate('mode_standard_desc');
  String get modeStandardFull => translate('mode_standard_full');
  String get modeStealth => translate('mode_stealth');
  String get modeStealthDesc => translate('mode_stealth_desc');
  String get modeStealthFull => translate('mode_stealth_full');
  String get modeBalanced => translate('mode_balanced');
  String get modeBalancedDesc => translate('mode_balanced_desc');
  String get modeBalancedFull => translate('mode_balanced_full');
  String get modeReconnectHint => translate('mode_reconnect_hint');

  // Settings - Auto Reconnect
  String get autoReconnect => translate('auto_reconnect');
  String get autoReconnectDesc => translate('auto_reconnect_desc');
  String get autoReconnectEnabled => translate('auto_reconnect_enabled');
  String get autoReconnectDisabled => translate('auto_reconnect_disabled');

  // Debug
  String get debug => translate('debug');
  String get debugInfo => translate('debug_info');
  String get show => translate('show');
  String get notLoggedIn => translate('not_logged_in');
  String get notRegistered => translate('not_registered');
  String get missing => translate('missing');
  String get lastVpnConfig => translate('last_vpn_config');
  String get noConfigYet => translate('no_config_yet');
  String get fullConfig => translate('full_config');
  String get viewFullConfig => translate('view_full_config');
  String get error => translate('error');
  String get failedLoadDebug => translate('failed_load_debug');
  String get deviceId => translate('device_id');
  String get apiKey => translate('api_key');

  // Logout
  String get logout => translate('logout');
  String get logoutConfirmation => translate('logout_confirmation');

  // VPN locations
  String get chooseLocationTitle => translate('choose_location_title');
  String get chooseLocationSubtitle => translate('choose_location_subtitle');
  String get locationAutomatic => translate('location_automatic');
  String get locationAutomaticDesc => translate('location_automatic_desc');
  String get locationRecommended => translate('location_recommended');
  String get locationListError => translate('location_list_error');
  String get locationUnavailableTitle => translate('location_unavailable_title');
  String get locationUseAutomatic => translate('location_use_automatic');
  String get locationChooseAnother => translate('location_choose_another');
  String get locationSwitching => translate('location_switching');
  String get locationConnectedVia => translate('location_connected_via');

  /// Text for an unavailable location (reason sent by the API)
  String locationReason(String? reason) {
    switch (reason) {
      case 'coming_soon':
        return translate('location_coming_soon');
      case 'maintenance':
        return translate('location_maintenance');
      case 'full':
        return translate('location_full');
      default:
        return translate('location_unavailable');
    }
  }

  /// Region label ("europe" -> "Europe"); unknown keys are shown as sent
  String region(String? key) {
    if (key == null || key.isEmpty) return '';
    final value = translate('region_$key');
    return value == 'region_$key' ? key : value;
  }

  // Free access
  String get freeAccessUntil => translate('free_access_until');
  String get subscribeToKeep => translate('subscribe_to_keep');
  String get subscribeNow => translate('subscribe_now');
  String get trialStartedTitle => translate('trial_started_title');
  String trialStartedMessage(int days, String date) =>
      translate('trial_started_message').replaceAll('{days}', '$days').replaceAll('{date}', date);

  /// Plan label for free subscriptions (source sent by the API), else null
  String? freePlanLabel(String? source) {
    switch (source) {
      case 'trial':
        return translate('free_trial');
      case 'gift':
        return translate('free_gift');
      default:
        return null;
    }
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['en', 'fr'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
