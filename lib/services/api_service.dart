import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://api.vulcainvpn.com/api';

  // ⭐ Log to file instead of console
  static Future<void> _log(String message) async {
    try {
      final timestamp = DateTime.now().toIso8601String();
      final logMessage = '$timestamp: $message\n';

      // Write to Documents folder on Windows
      if (Platform.isWindows) {
        final logPath = '${Platform.environment['USERPROFILE']}\\Documents\\VulcainVPN_API.log';
        final logFile = File(logPath);
        await logFile.writeAsString(logMessage, mode: FileMode.append);
      }

      print(message); // Still print for development/Android
    } catch (e) {
      print('Failed to write log: $e');
    }
  }

  // Generic authenticated request with auto-refresh
  static Future<Map<String, dynamic>> _makeAuthenticatedRequest(
    String endpoint, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    await _log('📊 Making $method request to: $endpoint');

    final token = await AuthService.getValidAccessToken();

    if (token == null) {
      await _log('❌ No valid authentication token');
      throw Exception('No valid authentication token');
    }

    await _log('✅ Token found (${token.length} chars)');

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

    await _log('📥 Response: ${response.statusCode}');

    // Handle 401 - token might have expired between check and request
    if (response.statusCode == 401) {
      await _log('⚠️  Token expired (401), attempting refresh...');
      final refreshed = await AuthService.refreshAccessToken();
      await _log('   Refresh result: ${refreshed ? "SUCCESS" : "FAILED"}');

      if (refreshed) {
        // Retry with new token
        final newToken = await AuthService.getValidAccessToken();
        await _log('   New token: ${newToken != null ? "EXISTS" : "NULL"}');
        headers['Authorization'] = 'Bearer $newToken';

        response = method == 'GET'
            ? await http.get(Uri.parse('$baseUrl/$endpoint'), headers: headers)
            : await http.post(
                Uri.parse('$baseUrl/$endpoint'),
                headers: headers,
                body: body != null ? json.encode(body) : null,
              );

        await _log('   Retry response: ${response.statusCode}');
      } else {
        await _log('   ❌ Refresh failed, logging out...');
        await AuthService.logout();
        throw Exception('Session expired - please login again');
      }
    }

    if (response.statusCode == 200) {
      await _log('✅ Request successful');
      return json.decode(response.body);
    } else {
      await _log('❌ Request failed: ${response.statusCode}');
      await _log('   Body: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
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
