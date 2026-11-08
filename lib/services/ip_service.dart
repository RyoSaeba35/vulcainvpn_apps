import 'package:http/http.dart' as http;
import 'dart:convert';

class IpService {
  /// The device's public IP and country, from our own backend
  /// (GET /api/whoami: the caller's IP and Cloudflare's country).
  ///
  /// It used to call ipinfo.io, ipapi.co and ipify.org, which sent every
  /// user's IP to third parties. When the VPN is on, this request goes
  /// through the tunnel, so it returns the VPN server's IP and country.
  static const String _whoamiUrl = 'https://api.vulcainvpn.com/api/whoami';

  static Future<Map<String, dynamic>> getPublicIpAndLocation() async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await http
            .get(Uri.parse(_whoamiUrl), headers: {'Cache-Control': 'no-cache'})
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          final countryCode = (data['country_code'] as String?) ?? 'Unknown';
          return {
            'ip': (data['ip'] as String?) ?? 'Unknown',
            'country': countryCode == 'Unknown' ? 'Unknown' : _countryCodeToName(countryCode),
            'countryCode': countryCode,
          };
        }
      } catch (e) {
        print('whoami failed (attempt $attempt): $e');
      }
    }

    return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
  }

  static String _countryCodeToName(String code) {
    const countries = {
      'FR': 'France',
      'US': 'United States',
      'GB': 'United Kingdom',
      'DE': 'Germany',
      'ES': 'Spain',
      'IT': 'Italy',
      'BE': 'Belgium',
      'CH': 'Switzerland',
      'NL': 'Netherlands',
      'PT': 'Portugal',
      'CA': 'Canada',
      'AU': 'Australia',
      'JP': 'Japan',
      'CN': 'China',
      'RU': 'Russia',
      'BR': 'Brazil',
      'IN': 'India',
      'MX': 'Mexico',
      'KR': 'South Korea',
      'SG': 'Singapore',
      'SE': 'Sweden',
      'NO': 'Norway',
      'DK': 'Denmark',
      'FI': 'Finland',
      'PL': 'Poland',
      'AT': 'Austria',
      'CZ': 'Czech Republic',
      'HU': 'Hungary',
      'RO': 'Romania',
      'TR': 'Turkey',
      'ZA': 'South Africa',
      'AE': 'United Arab Emirates',
      'SA': 'Saudi Arabia',
      'IL': 'Israel',
      'AR': 'Argentina',
      'CL': 'Chile',
      'CO': 'Colombia',
      'NZ': 'New Zealand',
      'TH': 'Thailand',
      'VN': 'Vietnam',
      'MY': 'Malaysia',
      'ID': 'Indonesia',
      'PH': 'Philippines',
      'HK': 'Hong Kong',
      'TW': 'Taiwan',
      'UA': 'Ukraine',
    };
    return countries[code] ?? code;
  }
}
