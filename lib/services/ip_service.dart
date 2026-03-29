import 'package:http/http.dart' as http;
import 'dart:convert';

class IpService {
  static Future<Map<String, dynamic>> getPublicIpAndLocation() async {
    // ✅ SECURITY: Only use HTTPS services to prevent IP leaks
    final services = [
      _tryIpInfo,      // Primary: ipinfo.io (HTTPS, includes location)
      _tryIpApiCo,     // Backup 1: ipapi.co (HTTPS, free tier with location)
      _tryIpify,       // Backup 2: ipify.org (HTTPS, IP only)
    ];

    for (var service in services) {
      try {
        final result = await service();
        if (result['ip'] != 'Unknown') {
          return result;
        }
      } catch (e) {
        print('Service failed: $e');
        continue;
      }
    }

    return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
  }

  // Primary: ipinfo.io (HTTPS)
  static Future<Map<String, dynamic>> _tryIpInfo() async {
    final response = await http
        .get(Uri.parse('https://ipinfo.io/json'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final countryCode = data['country'] ?? 'Unknown';
      return {
        'ip': data['ip'] ?? 'Unknown',
        'country': _countryCodeToName(countryCode),
        'countryCode': countryCode,
      };
    }
    return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
  }

  // Backup 1: ipapi.co (HTTPS, free tier with location)
  static Future<Map<String, dynamic>> _tryIpApiCo() async {
    final response = await http
        .get(Uri.parse('https://ipapi.co/json/'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'ip': data['ip'] ?? 'Unknown',
        'country': data['country_name'] ?? 'Unknown',
        'countryCode': data['country_code'] ?? 'Unknown',
      };
    }
    return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
  }

  // Backup 2: ipify (IP only, no location)
  static Future<Map<String, dynamic>> _tryIpify() async {
    final response = await http
        .get(Uri.parse('https://api.ipify.org?format=json'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'ip': data['ip'] ?? 'Unknown',
        'country': 'Unknown',
        'countryCode': 'Unknown',
      };
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
