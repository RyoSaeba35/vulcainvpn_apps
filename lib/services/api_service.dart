import 'package:http/http.dart' as http;
import 'dart:convert';
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://api.vulcainvpn.com/api';

  // Generic authenticated request with auto-refresh
  static Future<Map<String, dynamic>> _makeAuthenticatedRequest(
    String endpoint, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final token = await AuthService.getValidAccessToken();

    if (token == null) {
      throw Exception('No valid authentication token');
    }

    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };

    http.Response response;

    if (method == 'GET') {
      response = await http.get(Uri.parse('$baseUrl/$endpoint'), headers: headers);
    } else {
      response = await http.post(
        Uri.parse('$baseUrl/$endpoint'),
        headers: headers,
        body: body != null ? json.encode(body) : null,
      );
    }

    // Handle 401 - token might have expired between check and request
    if (response.statusCode == 401) {
      final refreshed = await AuthService.refreshAccessToken();
      if (refreshed) {
        // Retry with new token
        final newToken = await AuthService.getValidAccessToken();
        headers['Authorization'] = 'Bearer $newToken';

        response = method == 'GET'
            ? await http.get(Uri.parse('$baseUrl/$endpoint'), headers: headers)
            : await http.post(
                Uri.parse('$baseUrl/$endpoint'),
                headers: headers,
                body: body != null ? json.encode(body) : null,
              );
      } else {
        await AuthService.logout();
        throw Exception('Session expired - please login again');
      }
    }

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('API request failed: ${response.statusCode}');
    }
  }

  // Fetch subscription (uses JWT, not API key!)
  static Future<Map<String, dynamic>> fetchSubscription() async {
    return await _makeAuthenticatedRequest('subscription');
  }

  // Authenticated GET request
  static Future<Map<String, dynamic>> get(String endpoint) async {
    return await _makeAuthenticatedRequest(endpoint);
  }

  // Authenticated POST with api_key (for VPN operations)
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

  // Fetch status (uses API key for device-specific status)
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
