import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';  // ✅ FIX #9: For TimeoutException
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://api.vulcainvpn.com/api';

  // ✅ FIX #9: Network timeout configuration
  static const Duration _requestTimeout = Duration(seconds: 15);  // API requests
  static const Duration _connectionTimeout = Duration(seconds: 10);  // Initial connection

  // ⭐ Get exe directory (same as vpn_service_windows.dart)
  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  // ✅ FIX #4 PREVIEW: Simplified logging (file logging disabled to fix Windows issue)
  static Future<void> _log(String message) async {
    // Only print to console - no file writing
    // This prevents Windows file permission issues
    print(message);

    /* ORIGINAL FILE LOGGING (disabled for now):
    try {
      final timestamp = DateTime.now().toIso8601String();
      final logMessage = '$timestamp: $message\n';

      if (Platform.isWindows) {
        final logPath = '$_exeDir\\api_log.txt';
        final logFile = File(logPath);

        if (await logFile.exists()) {
          final size = await logFile.length();
          if (size > 1024 * 1024) {
            await logFile.rename('$_exeDir\\api_log_old.txt');
          }
        }

        await logFile.writeAsString(logMessage, mode: FileMode.append);
      }

      print(message);
    } catch (e) {
      print('Failed to write log: $e');
    }
    */
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

    try {
      // ✅ FIX #9: Add timeout to prevent hanging connections
      if (method == 'GET') {
        response = await http.get(
          Uri.parse('$baseUrl/$endpoint'),
          headers: headers,
        ).timeout(_requestTimeout);
      } else {
        response = await http.post(
          Uri.parse('$baseUrl/$endpoint'),
          headers: headers,
          body: body != null ? json.encode(body) : null,
        ).timeout(_requestTimeout);
      }

      await _log('📥 Response: ${response.statusCode}');
    } on TimeoutException catch (e) {
      // ✅ FIX #9: Handle timeout specifically
      await _log('❌ Request timeout after ${_requestTimeout.inSeconds}s: $e');
      throw Exception('Request timeout - please check your connection');
    } catch (e) {
      await _log('❌ Network error: $e');
      throw Exception('Network error: $e');
    }

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

        try {
          // ✅ FIX #9: Add timeout to retry requests too
          response = method == 'GET'
              ? await http.get(
                  Uri.parse('$baseUrl/$endpoint'),
                  headers: headers,
                ).timeout(_requestTimeout)
              : await http.post(
                  Uri.parse('$baseUrl/$endpoint'),
                  headers: headers,
                  body: body != null ? json.encode(body) : null,
                ).timeout(_requestTimeout);

          await _log('   Retry response: ${response.statusCode}');
        } on TimeoutException catch (e) {
          // ✅ FIX #9: Handle retry timeout
          await _log('   ❌ Retry timeout after ${_requestTimeout.inSeconds}s: $e');
          throw Exception('Retry timeout - please check your connection');
        } catch (e) {
          await _log('   ❌ Retry failed: $e');
          throw Exception('Retry failed: $e');
        }
      } else {
        await _log('   ❌ Refresh failed, logging out...');
        await AuthService.logout();
        throw Exception('Session expired - please login again');
      }
    }

    if (response.statusCode == 200) {
      await _log('✅ Request successful');
      try {
        return json.decode(response.body);
      } catch (e) {
        await _log('❌ JSON decode error: $e');
        await _log('   Response body: ${response.body}');
        throw Exception('Failed to parse response: $e');
      }
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

    try {
      // ✅ FIX #9: Add timeout to API key requests
      final response = await http.post(
        Uri.parse('$baseUrl/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
        },
      ).timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body);
      } else if (response.statusCode == 429) {
        throw Exception('Maximum devices reached');
      } else {
        throw Exception('Request failed: ${response.statusCode}');
      }
    } on TimeoutException catch (e) {
      // ✅ FIX #9: Handle API key request timeout
      throw Exception('Request timeout - please check your connection');
    }
  }

  // Fetch status (uses API key for device-specific status)
  static Future<Map<String, dynamic>> fetchStatus() async {
    final apiKey = await AuthService.getApiKey();
    if (apiKey == null) throw Exception('No API key found');

    try {
      // ✅ FIX #9: Add timeout to status requests
      final response = await http.get(
        Uri.parse('$baseUrl/status'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
        },
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load status');
      }
    } on TimeoutException catch (e) {
      // ✅ FIX #9: Handle status request timeout
      throw Exception('Request timeout - please check your connection');
    }
  }
}
