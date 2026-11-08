import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// One country offered by the backend (GET /api/locations).
class VpnLocation {
  final String code;
  final String name;
  final String nameFr;
  final String? region;
  final String flag;
  final bool available;

  /// Why it is not available: coming_soon | maintenance | no_server | full
  final String? reason;

  /// low | medium | high (only when available)
  final String? load;

  const VpnLocation({
    required this.code,
    required this.name,
    required this.nameFr,
    required this.region,
    required this.flag,
    required this.available,
    required this.reason,
    required this.load,
  });

  factory VpnLocation.fromJson(Map<String, dynamic> json) {
    final code = (json['country_code'] ?? '').toString().toUpperCase();
    return VpnLocation(
      code: code,
      name: (json['name'] ?? code).toString(),
      nameFr: (json['name_fr'] ?? json['name'] ?? code).toString(),
      region: json['region'] as String?,
      flag: (json['flag'] ?? '').toString(),
      available: json['available'] == true,
      reason: json['reason'] as String?,
      load: json['load'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'country_code': code,
        'name': name,
        'name_fr': nameFr,
        'region': region,
        'flag': flag,
        'available': available,
        'reason': reason,
        'load': load,
      };

  String displayName(String languageCode) => languageCode == 'fr' ? nameFr : name;
}

/// Location picker state: the list from the backend and the user's choice.
///
/// The choice ("auto" or a country code) is stored on the device and sent to
/// POST /api/connect as {"location": "..."} by every platform's startVpn.
/// Reconnects made by the Android native services reuse the stored config,
/// so they stay on the same server (no silent change of country).
class LocationService {
  static const String automatic = 'auto';
  static const String _selectedKey = 'vpn_location_selected';
  static const String _cacheKey = 'vpn_locations_cache';
  static const String _connectedKey = 'vpn_connected_country';

  /// Current choice, for widgets that want to listen to it
  static final ValueNotifier<String> selected = ValueNotifier<String>(automatic);

  /// Country of the server of the last successful connect ("FR"), or null
  static final ValueNotifier<String?> connectedCountry = ValueNotifier<String?>(null);

  static List<VpnLocation> _locations = const [];
  static List<VpnLocation> get locations => _locations;

  static VpnLocation? byCode(String code) {
    for (final location in _locations) {
      if (location.code == code) return location;
    }
    return null;
  }

  /// Loads the saved choice and the cached list (no network). Call once at startup.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      selected.value = prefs.getString(_selectedKey) ?? automatic;
      // Server country of the last connect, so the map is right when the app
      // reopens while the VPN is still running
      connectedCountry.value = prefs.getString(_connectedKey);
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        final list = json.decode(cached) as List<dynamic>;
        _locations = list
            .map((e) => VpnLocation.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (e) {
      if (kDebugMode) print('LocationService.init failed: $e');
    }
  }

  /// Fetches the list from the backend. Returns true on success; on failure
  /// the cached list stays in [locations].
  static Future<bool> refresh() async {
    try {
      final data = await ApiService.get('locations');
      final list = (data['locations'] as List<dynamic>? ?? [])
          .map((e) => VpnLocation.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((l) => l.code.isNotEmpty)
          .toList();
      _locations = list;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, json.encode(list.map((l) => l.toJson()).toList()));

      // A country removed by the admin falls back to Automatic
      if (selected.value != automatic && byCode(selected.value) == null) {
        await select(automatic);
      }
      return true;
    } catch (e) {
      if (kDebugMode) print('LocationService.refresh failed: $e');
      return false;
    }
  }

  static Future<String> getSelected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_selectedKey) ?? automatic;
      selected.value = value;
      return value;
    } catch (_) {
      return selected.value;
    }
  }

  static Future<void> select(String code) async {
    final value = code.isEmpty ? automatic : code;
    selected.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedKey, value);
    } catch (e) {
      if (kDebugMode) print('LocationService.select failed: $e');
    }
  }

  /// JSON body for POST /api/connect
  static Future<String> connectBody() async {
    return json.encode({'location': await getSelected()});
  }

  /// Reads the server country from a /api/connect response body
  static void rememberConnectedServer(Map<String, dynamic> response) {
    final server = response['server'];
    if (server is Map && server['country'] != null) {
      final country = server['country'].toString().toUpperCase();
      connectedCountry.value = country;
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(_connectedKey, country))
          .catchError((_) => false);
    }
  }

  /// Error prefix thrown by startVpn when the backend answers 409
  static const String unavailableErrorPrefix = 'LOCATION_UNAVAILABLE|';
}
