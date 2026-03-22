// lib/services/api_service.dart
// lib/services/api_service.dart
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://api.vulcainvpn.com/api';

  // Authenticated GET request
  static Future<Map<String, dynamic>> get(String endpoint) async {
    final token = await AuthService.getToken();
    if (token == null) throw Exception('Not authenticated');

    final response = await http.get(
      Uri.parse('$baseUrl/$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else if (response.statusCode == 401) {
      await AuthService.logout();
      throw Exception('Session expired');
    } else {
      throw Exception('Request failed: ${response.statusCode}');
    }
  }

  // Authenticated POST with api_key
  static Future<Map<String, dynamic>> postWithApiKey(String endpoint) async {
    final apiKey = await AuthService.getApiKey();
    if (apiKey == null) throw Exception('No API key found');

    final response = await http.post(
      Uri.parse('$baseUrl/$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'X-Api-Key': apiKey,
      },
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(response.body);
    } else if (response.statusCode == 429) {
      throw Exception('Maximum devices reached');
    } else {
      throw Exception('Request failed: ${response.statusCode}');
    }
  }

  // Fetch subscription status
  static Future<Map<String, dynamic>> fetchStatus() async {
    final apiKey = await AuthService.getApiKey();
    if (apiKey == null) throw Exception('No API key found');

    final response = await http.get(
      Uri.parse('$baseUrl/status'),
      headers: {
        'Content-Type': 'application/json',
        'X-Api-Key': apiKey,
      },
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load status');
    }
  }
}
