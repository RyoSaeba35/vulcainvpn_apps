import 'package:http/http.dart' as http;
import 'dart:convert';

class IpService {
  static Future<Map<String, dynamic>> getPublicIpAndLocation() async {
    try {
      final ipResponse = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 5));

      if (ipResponse.statusCode == 200) {
        final ipData = json.decode(ipResponse.body);
        final ip = ipData['ip'] ?? 'Unknown';

        final locationResponse = await http
            .get(Uri.parse('https://ip-api.com/json/$ip'))
            .timeout(const Duration(seconds: 5));

        if (locationResponse.statusCode == 200) {
          final locationData = json.decode(locationResponse.body);
          return {
            'ip': ip,
            'country': locationData['country'] ?? 'Unknown',
            'countryCode': locationData['countryCode'] ?? 'Unknown',
          };
        }
        return {'ip': ip, 'country': 'Unknown', 'countryCode': 'Unknown'};
      }
      return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
    } catch (e) {
      print('Error fetching IP/location: $e');
      return {'ip': 'Unknown', 'country': 'Unknown', 'countryCode': 'Unknown'};
    }
  }
}
