import 'package:http/http.dart' as http;
import 'dart:convert';

class IpService {
  static Future<Map<String, dynamic>> getPublicIpAndLocation() async {
    try {
      final response = await http
          .get(Uri.parse('https://ipinfo.io/json'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final ip = data['ip'] ?? 'Unknown';
        final country = data['country'] ?? 'Unknown';

        // ipinfo returns country code only, convert to full name
        final countryName = _countryCodeToName(country);

        return {
          'ip': ip,
          'country': countryName,
          'countryCode': country,
        };
      }
      return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
    } catch (e) {
      print('Error fetching IP/location: $e');
      return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
    }
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
