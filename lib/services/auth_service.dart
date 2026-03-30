import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:math';  // ✅ FIX #7: For cryptographically secure random
import 'package:device_info_plus/device_info_plus.dart';

class AuthService {
  static const String _baseUrl = 'https://api.vulcainvpn.com/api';
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _apiKeyKey = 'api_key';
  static const String _deviceIdKey = 'device_id';
  static const String _emailKey = 'user_email';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    wOptions: WindowsOptions(
      useBackwardCompatibility: true,
    ),
  );

  // Login — stores both access and refresh tokens
  static Future<bool> login(String email, String password) async {
    try {
      // Step 1 — Login and get tokens
      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password}),
      );

      if (response.statusCode != 200) return false;

      final data = json.decode(response.body);

      // Store both tokens
      await _storage.write(key: _accessTokenKey, value: data['access_token']);
      await _storage.write(key: _refreshTokenKey, value: data['refresh_token']);
      await saveEmail(data['user']['email']);

      // Step 2 — Generate unique device ID
      final deviceId = await _getDeviceId();
      final platform = Platform.isAndroid ? 'android' :
                       Platform.isIOS ? 'ios' :
                       Platform.isWindows ? 'windows' :
                       Platform.isMacOS ? 'macos' : 'linux';
      final deviceName = await _getDeviceName();

      // Step 3 — Register device and store api_key
      final registerResponse = await http.post(
        Uri.parse('$_baseUrl/devices/register'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${data['access_token']}',
        },
        body: json.encode({
          'device_id': deviceId,
          'platform': platform,
          'name': deviceName,
        }),
      );

      if (registerResponse.statusCode == 200 ||
          registerResponse.statusCode == 201) {
        final registerData = json.decode(registerResponse.body);
        await saveApiKey(registerData['api_key']);
        await saveDeviceId(deviceId);
      }

      return true;
    } catch (e) {
      print('Login error: $e');
      return false;
    }
  }

  // Refresh the access token
  static Future<bool> refreshAccessToken() async {
    try {
      final refreshToken = await _storage.read(key: _refreshTokenKey);
      if (refreshToken == null) return false;

      final response = await http.post(
        Uri.parse('$_baseUrl/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Store new tokens (both are rotated)
        await _storage.write(key: _accessTokenKey, value: data['access_token']);
        await _storage.write(key: _refreshTokenKey, value: data['refresh_token']);

        return true;
      }
      return false;
    } catch (e) {
      print('Token refresh error: $e');
      return false;
    }
  }

  // Get valid access token (auto-refresh if needed)
  static Future<String?> getValidAccessToken() async {
    String? accessToken = await _storage.read(key: _accessTokenKey);

    if (accessToken == null) return null;

    // Check if token is expiring in next 5 minutes
    if (_isTokenExpiringSoon(accessToken)) {
      print('Token expiring soon, refreshing...');
      final refreshed = await refreshAccessToken();
      if (!refreshed) return null;
      accessToken = await _storage.read(key: _accessTokenKey);
    }

    return accessToken;
  }

  // Check if JWT is expiring in next 5 minutes
  static bool _isTokenExpiringSoon(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;

      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );

      final exp = payload['exp'];
      if (exp == null) return false;

      final expiryDate = DateTime.fromMillisecondsSinceEpoch(exp * 1000);

      // Refresh if less than 5 minutes remaining
      return DateTime.now().isAfter(expiryDate.subtract(const Duration(minutes: 5)));
    } catch (e) {
      print('Token decode error: $e');
      return true;
    }
  }

  // Logout — calls backend and clears all stored credentials
  static Future<void> logout() async {
    try {
      final token = await _storage.read(key: _accessTokenKey);
      if (token != null) {
        await http.delete(
          Uri.parse('$_baseUrl/logout'),
          headers: {'Authorization': 'Bearer $token'},
        );
      }
    } catch (e) {
      print('Logout API call failed: $e');
    }

    await _storage.deleteAll();
  }

  // DEPRECATED: Use getValidAccessToken() instead
  static Future<String?> getToken() async {
    return await getValidAccessToken();
  }

  // Check if user is logged in (checks refresh token existence)
  static Future<bool> isLoggedIn() async {
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    return refreshToken != null;
  }

  // Store api_key after device registration
  static Future<void> saveApiKey(String apiKey) async {
    await _storage.write(key: _apiKeyKey, value: apiKey);
  }

  // Get stored api_key
  static Future<String?> getApiKey() async {
    return await _storage.read(key: _apiKeyKey);
  }

  // Store device_id
  static Future<void> saveDeviceId(String deviceId) async {
    await _storage.write(key: _deviceIdKey, value: deviceId);
  }

  // Get stored device_id
  static Future<String?> getDeviceId() async {
    return await _storage.read(key: _deviceIdKey);
  }

  // Save email on login
  static Future<void> saveEmail(String email) async {
    await _storage.write(key: _emailKey, value: email);
  }

  // Get stored email
  static Future<String?> getStoredEmail() async {
    return await _storage.read(key: _emailKey);
  }

  // ─── Private helpers ───────────────────────────────────────────────────────

  static Future<String> _getDeviceId() async {
    // Reuse stored device ID if available
    final stored = await _storage.read(key: _deviceIdKey);
    if (stored != null) return stored;

    try {
      final deviceInfo = DeviceInfoPlugin();
      String id;

      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        id = info.id;
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        id = info.identifierForVendor ?? _generateFallbackId();
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        id = info.deviceId;
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        id = info.systemGUID ?? _generateFallbackId();
      } else {
        id = _generateFallbackId();
      }

      return id;
    } catch (e) {
      return _generateFallbackId();
    }
  }

  /// ✅ FIX #7: Generate cryptographically secure device ID
  ///
  /// Uses UUID v4 format with Random.secure() for unpredictable IDs
  /// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  /// - 4: version 4 (random)
  /// - y: variant bits (8, 9, a, or b)
  static String _generateFallbackId() {
    final random = Random.secure();

    // Generate 16 random bytes
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // Set version to 4 (random UUID)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;

    // Set variant to RFC 4122
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    // Convert to UUID string format
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
           '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
           '${hex.substring(20, 32)}';
  }

  static Future<String> _getDeviceName() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        return '${info.brand} ${info.model}';
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        return info.name;
      } else if (Platform.isWindows) {
        final info = await deviceInfo.windowsInfo;
        return info.computerName;
      } else if (Platform.isMacOS) {
        final info = await deviceInfo.macOsInfo;
        return info.computerName;
      }
    } catch (e) {
      return 'Unknown Device';
    }
    return 'Unknown Device';
  }
}
