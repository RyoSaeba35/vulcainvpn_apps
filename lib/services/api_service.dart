import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';  // ✅ FIX #9: For TimeoutException
import 'package:flutter/foundation.dart';  // ✅ FIX #15: For kDebugMode
import 'auth_service.dart';

class ApiService {
  static const String baseUrl = 'https://api.vulcainvpn.com/api';

  // ✅ FIX #9: Network timeout configuration
  static const Duration _requestTimeout = Duration(seconds: 15);  // API requests
  static const Duration _connectionTimeout = Duration(seconds: 10);  // Initial connection

  // ✅ FIX #11: API rate limiting protection
  static final Map<String, DateTime> _lastRequestTimes = {};
  static const Duration _minRequestInterval = Duration(milliseconds: 500);  // 500ms between requests

  // ✅ FIX #15: User-Agent header for API requests
  static const String _userAgent = 'VulcainVPN/1.0';

  // ⭐ Get exe directory (same as vpn_service_windows.dart)
  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  // ✅ FIX #4 PREVIEW: Simplified logging (file logging disabled to fix Windows issue)
  static Future<void> _log(String message) async {
    // ✅ FIX #15: Only log in debug mode for production security
    if (kDebugMode) {
      print(message);
    }

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

  // ✅ FIX #11: Check and enforce rate limiting
  static Future<void> _checkRateLimit(String endpoint) async {
    // ✅ FIX #11: Clean up old entries (prevent unbounded growth)
    if (_lastRequestTimes.length > 50) {
      final now = DateTime.now();
      _lastRequestTimes.removeWhere((key, value) =>
        now.difference(value) > Duration(minutes: 5)
      );
    }

    final lastTime = _lastRequestTimes[endpoint];

    if (lastTime != null) {
      final timeSinceLastRequest = DateTime.now().difference(lastTime);

      if (timeSinceLastRequest < _minRequestInterval) {
        final waitTime = _minRequestInterval - timeSinceLastRequest;
        await _log('⏱️ Rate limit: waiting ${waitTime.inMilliseconds}ms for $endpoint');
        await Future.delayed(waitTime);
      }
    }

    // Update last request time
    _lastRequestTimes[endpoint] = DateTime.now();
  }

  // ✅ FIX #12: Sanitize error messages to prevent information leakage
  static String _sanitizeError(dynamic error) {
    final errorStr = error.toString();

    // Remove file paths (Windows and Unix style)
    var sanitized = errorStr.replaceAll(
      RegExp(r'[A-Z]:\\[^\s]+\.dart|\/[^\s]+\.dart'),
      '[file]'
    );

    // Remove IP addresses
    sanitized = sanitized.replaceAll(
      RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'),
      '[ip]'
    );

    // Remove tokens/keys (base64-like strings, 20+ chars)
    sanitized = sanitized.replaceAll(
      RegExp(r'[A-Za-z0-9+/]{20,}={0,2}'),
      '[token]'
    );

    // Remove Bearer tokens specifically
    sanitized = sanitized.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+'),
      'Bearer [token]'
    );

    // Remove URLs with sensitive info
    sanitized = sanitized.replaceAll(
      RegExp(r'https?://[^\s]+'),
      '[url]'
    );

    return sanitized;
  }

  // ✅ FIX #15: Generate unique request ID for debugging/correlation
  static String _generateRequestId() {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  // Generic authenticated request with auto-refresh
  static Future<Map<String, dynamic>> _makeAuthenticatedRequest(
    String endpoint, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    // ✅ FIX #11: Enforce rate limiting before making request
    await _checkRateLimit(endpoint);

    // ✅ FIX #15: Generate request ID for correlation
    final requestId = _generateRequestId();
    await _log('📊 [$requestId] Making $method request to: $endpoint');

    final token = await AuthService.getValidAccessToken();

    if (token == null) {
      await _log('❌ [$requestId] No valid authentication token');
      throw Exception('No valid authentication token');
    }

    await _log('✅ [$requestId] Token found (${token.length} chars)');

    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'User-Agent': _userAgent,  // ✅ FIX #15: Professional User-Agent header
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

      await _log('📥 [$requestId] Response: ${response.statusCode}');
    } on TimeoutException catch (e) {
      // ✅ FIX #9: Handle timeout specifically
      // ✅ FIX #12: Sanitize error message
      final sanitized = _sanitizeError(e);
      await _log('❌ [$requestId] Request timeout after ${_requestTimeout.inSeconds}s: $sanitized');
      throw Exception('Request timeout - please check your connection');
    } catch (e) {
      // ✅ FIX #12: Sanitize error message
      final sanitized = _sanitizeError(e);
      await _log('❌ [$requestId] Network error: $sanitized');
      throw Exception('Network error: $sanitized');
    }

    // Handle 401 - token might have expired between check and request
    if (response.statusCode == 401) {
      await _log('⚠️ [$requestId] Token expired (401), attempting refresh...');
      final refreshed = await AuthService.refreshAccessToken();
      await _log('   [$requestId] Refresh result: ${refreshed ? "SUCCESS" : "FAILED"}');

      if (refreshed) {
        // Retry with new token
        final newToken = await AuthService.getValidAccessToken();
        await _log('   [$requestId] New token: ${newToken != null ? "EXISTS" : "NULL"}');
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

          await _log('   [$requestId] Retry response: ${response.statusCode}');
        } on TimeoutException catch (e) {
          // ✅ FIX #9: Handle retry timeout
          // ✅ FIX #12: Sanitize error message
          final sanitized = _sanitizeError(e);
          await _log('   ❌ [$requestId] Retry timeout after ${_requestTimeout.inSeconds}s: $sanitized');
          throw Exception('Retry timeout - please check your connection');
        } catch (e) {
          // ✅ FIX #12: Sanitize error message
          final sanitized = _sanitizeError(e);
          await _log('   ❌ [$requestId] Retry failed: $sanitized');
          throw Exception('Retry failed: $sanitized');
        }
      } else {
        await _log('   ❌ [$requestId] Refresh failed, logging out...');
        await AuthService.logout();
        throw Exception('Session expired - please login again');
      }
    }

    if (response.statusCode == 200) {
      await _log('✅ [$requestId] Request successful');
      try {
        return json.decode(response.body);
      } catch (e) {
        // ✅ FIX #12: Sanitize error and response body
        final sanitized = _sanitizeError(e);
        final sanitizedBody = _sanitizeError(response.body);
        await _log('❌ [$requestId] JSON decode error: $sanitized');
        await _log('   [$requestId] Response body: $sanitizedBody');
        throw Exception('Failed to parse response: $sanitized');
      }
    } else {
      // ✅ FIX #12: Sanitize response body before logging
      final bodyPreview = response.body.substring(0, response.body.length > 200 ? 200 : response.body.length);
      final sanitizedBody = _sanitizeError(bodyPreview);
      await _log('❌ [$requestId] Request failed: ${response.statusCode}');
      await _log('   [$requestId] Body: $sanitizedBody');
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
    // ✅ FIX #11: Enforce rate limiting
    await _checkRateLimit(endpoint);

    final apiKey = await AuthService.getApiKey();
    if (apiKey == null) throw Exception('No API key found');

    try {
      // ✅ FIX #9: Add timeout to API key requests
      final response = await http.post(
        Uri.parse('$baseUrl/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
          'User-Agent': _userAgent,  // ✅ FIX #15: Professional User-Agent header
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
      // ✅ FIX #12: Sanitize error message
      final sanitized = _sanitizeError(e);
      await _log('❌ API key request timeout: $sanitized');
      throw Exception('Request timeout - please check your connection');
    } catch (e) {
      // ✅ FIX #12: Sanitize unexpected errors
      final sanitized = _sanitizeError(e);
      await _log('❌ API key request error: $sanitized');
      throw Exception('Request failed: $sanitized');
    }
  }

  // Fetch status (uses API key for device-specific status)
  static Future<Map<String, dynamic>> fetchStatus() async {
    // ✅ FIX #11: Enforce rate limiting
    await _checkRateLimit('status');

    final apiKey = await AuthService.getApiKey();
    if (apiKey == null) throw Exception('No API key found');

    try {
      // ✅ FIX #9: Add timeout to status requests
      final response = await http.get(
        Uri.parse('$baseUrl/status'),
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
          'User-Agent': _userAgent,  // ✅ FIX #15: Professional User-Agent header
        },
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load status');
      }
    } on TimeoutException catch (e) {
      // ✅ FIX #9: Handle status request timeout
      // ✅ FIX #12: Sanitize error message
      final sanitized = _sanitizeError(e);
      await _log('❌ Status request timeout: $sanitized');
      throw Exception('Request timeout - please check your connection');
    } catch (e) {
      // ✅ FIX #12: Sanitize unexpected errors
      final sanitized = _sanitizeError(e);
      await _log('❌ Status request error: $sanitized');
      throw Exception('Failed to load status: $sanitized');
    }
  }

  // ✅ FIX #11: Clear rate limit cache (call on logout)
  static void clearRateLimitCache() {
    _lastRequestTimes.clear();
  }
}
