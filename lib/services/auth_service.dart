import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String _baseUrl = 'https://api.vulcainvpn.com/api';
  static const String _accessTokenKey = 'access_token';
  static const String _refreshTokenKey = 'refresh_token';
  static const String _apiKeyKey = 'api_key';
  static const String _deviceIdKey = 'device_id';
  static const String _emailKey = 'user_email';
  static const String _tokenExpiryKey = 'token_expiry';

  static const Duration _authTimeout = Duration(seconds: 15);

  // ✅ Migration tracking flag (in-memory, resets each app session)
  static bool _hasCheckedMigration = false;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
    wOptions: WindowsOptions(
      useBackwardCompatibility: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
    mOptions: MacOsOptions(
      useDataProtectionKeyChain: false,
    ),
  );

  static Future<void> _macSave(String key, String value) async {
    if (!Platform.isMacOS) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mac_fallback_$key', value);
  }

  static Future<String?> _macRead(String key) async {
    if (!Platform.isMacOS) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('mac_fallback_$key');
  }

  static Future<void> _write(String key, String value) async {
    if (Platform.isMacOS) {
      await _macSave(key, value);
    } else {
      await _storage.write(key: key, value);
    }
  }

  static Future<String?> _read(String key) async {
    if (Platform.isMacOS) {
      return await _macRead(key);
    }
    return await _storage.read(key: key);
  }

  static Future<void> initialize() async {
    final loggedIn = await isLoggedIn();
    if (loggedIn) {
      await _migrateOldDeviceId();
    }
  }

  // ✅ NEW: Migrate old device_id to email-scoped storage
  static Future<void> _migrateOldDeviceId() async {
    // Skip if we already checked this session
    if (_hasCheckedMigration) return;
    _hasCheckedMigration = true;

    try {
      final email = await getStoredEmail();
      if (email == null) return;

      final emailKey = '${_deviceIdKey}_$email';
      final emailScoped = await _read(emailKey);

      // Already migrated - nothing to do
      if (emailScoped != null && emailScoped.isNotEmpty) {
        return;
      }

      // Check if old generic device_id exists
      final oldDeviceId = await _read(_deviceIdKey);
      if (oldDeviceId != null && oldDeviceId.isNotEmpty) {
        print('🔄 Migrating old device_id to email-scoped storage...');
        print('   Old key: $_deviceIdKey');
        print('   New key: $emailKey');
        print('   device_id: $oldDeviceId');

        // Copy to email-scoped key
        await _write(emailKey, oldDeviceId);

        print('✅ Migration complete!');
      }
    } catch (e) {
      print('⚠️ Migration failed (non-critical): $e');
    }
  }

  // Login — stores both access and refresh tokens
  static Future<bool> login(String email, String password) async {
    // Validate inputs before sending
    if (email.isEmpty || password.isEmpty) {
      print('❌ Empty credentials');
      return false;
    }

    // Basic email validation
    final emailRegex = RegExp(r'^[\w\-\.]+@([\w\-]+\.)+[\w\-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      print('❌ Invalid email format');
      return false;
    }

    // Password length check
    if (password.length < 6) {
      print('❌ Password too short (minimum 6 characters)');
      return false;
    }

    // Sanitize email (remove whitespace, lowercase)
    final sanitizedEmail = email.trim().toLowerCase();

    try {
      // Step 1 — Login and get tokens
      print('🔐 Logging in as $sanitizedEmail...');

      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'email': sanitizedEmail,
          'password': password,
        }),
      ).timeout(_authTimeout);

      if (response.statusCode != 200) {
        print('❌ Login failed: ${response.statusCode}');
        return false;
      }

      final data = json.decode(response.body);

      print('✅ Login successful');

      // Store both tokens
      await _write(_accessTokenKey, data['access_token']);
      await _write(_refreshTokenKey, data['refresh_token']);
      await saveEmail(data['user']['email']);

      // Store token expiry time for better tracking
      await _storeTokenExpiry(data['access_token']);

      // Step 2 — Generate unique device ID
      print('📱 Generating device credentials...');
      final deviceId = await _getDeviceId();
      final platform = Platform.isAndroid ? 'android' :
                       Platform.isIOS ? 'ios' :
                       Platform.isWindows ? 'windows' :
                       Platform.isMacOS ? 'macos' : 'linux';
      final deviceName = await _getDeviceName();

      print('📱 Device info:');
      print('   device_id: $deviceId');
      print('   platform: $platform');
      print('   name: $deviceName');

      // Step 3 — Register device and store api_key
      print('📱 Registering device with backend...');

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
      ).timeout(_authTimeout);

      print('📱 Registration response: ${registerResponse.statusCode}');

      if (registerResponse.statusCode == 200 || registerResponse.statusCode == 201) {
        final registerData = json.decode(registerResponse.body);

        print('🔑 Registration successful!');
        print('   api_key: ${registerData['api_key']}');
        print('   returned device_id: ${registerData['device_id']}');

        await saveApiKey(registerData['api_key']);

        // Verify credentials were saved
        final savedApiKey = await getApiKey();
        final savedDeviceId = await getDeviceId();

        print('✅ Credentials saved to storage:');
        print('   saved api_key: ${savedApiKey?.substring(0, 16)}...');
        print('   saved device_id: $savedDeviceId');

        return true;
      } else {
        print('❌ Device registration FAILED: ${registerResponse.statusCode}');
        print('   Response body: ${registerResponse.body}');

        // Login succeeded but device registration failed
        // User will see "device not registered" when trying to connect
        return true;
      }
    } catch (e) {
      print('❌ Login error: $e');
      return false;
    }
  }

  // Refresh the access token
  static Future<bool> refreshAccessToken() async {
    try {
      final refreshToken = await _read(_refreshTokenKey);
      if (refreshToken == null) return false;

      // Retry token refresh once on failure (network resilience)
      for (int attempt = 1; attempt <= 2; attempt++) {
        try {
          final response = await http.post(
            Uri.parse('$_baseUrl/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'refresh_token': refreshToken}),
          ).timeout(_authTimeout);

          if (response.statusCode == 200) {
            final data = json.decode(response.body);

            // Store new tokens (both are rotated)
            await _write(_accessTokenKey, data['access_token']);
            await _write(_refreshTokenKey, data['refresh_token']);

            // Store new token expiry
            await _storeTokenExpiry(data['access_token']);

            print('✅ Token refreshed successfully${attempt > 1 ? " (retry $attempt)" : ""}');
            return true;
          }

          // Don't retry on 401 (invalid refresh token)
          if (response.statusCode == 401) {
            print('❌ Refresh token invalid, logout required');
            return false;
          }

          // Retry on other errors
          if (attempt < 2) {
            print('⚠️ Token refresh failed (attempt $attempt), retrying...');
            await Future.delayed(Duration(seconds: 1));
            continue;
          }

          return false;
        } on TimeoutException {
          if (attempt < 2) {
            print('⚠️ Token refresh timeout (attempt $attempt), retrying...');
            await Future.delayed(Duration(seconds: 1));
            continue;
          }
          print('❌ Token refresh timeout after $attempt attempts');
          return false;
        }
      }

      return false;
    } catch (e) {
      print('Token refresh error: $e');
      return false;
    }
  }

  // Get valid access token (auto-refresh if needed)
  static Future<String?> getValidAccessToken() async {
    String? accessToken = await _read(_accessTokenKey);

    if (accessToken == null) return null;

    // Check if token is expiring in next 5 minutes
    if (_isTokenExpiringSoon(accessToken)) {
      print('Token expiring soon, refreshing...');
      final refreshed = await refreshAccessToken();
      if (!refreshed) return null;
      accessToken = await _read(_accessTokenKey);
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

  // Store token expiry timestamp for better tracking
  static Future<void> _storeTokenExpiry(String token) async {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;

      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );

      final exp = payload['exp'];
      if (exp != null) {
        await _write(
          key: _tokenExpiryKey,
          exp.toString(),
        );
      }
    } catch (e) {
      print('Failed to store token expiry: $e');
    }
  }

  // Logout — calls backend and clears all stored credentials
  static Future<void> logout() async {
    try {
      final token = await _read(_accessTokenKey);
      if (token != null) {
        await http.delete(
          Uri.parse('$_baseUrl/logout'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(_authTimeout);
      }
    } catch (e) {
      print('Logout API call failed: $e');
    }

    // Comprehensive session cleanup
    await _storage.deleteAll();
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('mac_fallback_')).toList();
      for (final key in keys) await prefs.remove(key);
    }
  }

  // DEPRECATED: Use getValidAccessToken() instead
  static Future<String?> getToken() async {
    return await getValidAccessToken();
  }

  // Check if user is logged in (checks refresh token existence)
  static Future<bool> isLoggedIn() async {
    final refreshToken = await _read(_refreshTokenKey);
    return refreshToken != null;
  }

  // Store api_key after device registration
  static Future<void> saveApiKey(String apiKey) async {
    await _write(_apiKeyKey, apiKey);
    await _macSave(_apiKeyKey, apiKey);
  }

  // Get stored api_key
  static Future<String?> getApiKey() async {
    return await _read(_apiKeyKey) ?? await _macRead(_apiKeyKey);
  }

  // ✅ UPDATED: Get stored device_id with lazy migration fallback
  static Future<String?> getDeviceId() async {
    final email = await getStoredEmail();
    if (email == null) {
      print('⚠️ Cannot get device ID - user not logged in');
      return await _macRead(_deviceIdKey);
    }

    final emailKey = '${_deviceIdKey}_$email';
    final deviceId = await _read(emailKey);

    // Found in email-scoped key
    if (deviceId != null && deviceId.isNotEmpty) {
      return deviceId;
    }

    // ✅ LAZY MIGRATION: Check old generic key as fallback
    print('⚠️ Device ID not found in email-scoped storage, checking old location...');
    final oldDeviceId = await _read(_deviceIdKey);

    if (oldDeviceId != null && oldDeviceId.isNotEmpty) {
      print('🔄 Found old device_id, migrating now...');
      print('   Migrating: $oldDeviceId');

      // Migrate to email-scoped key
      await _write(emailKey, oldDeviceId);

      print('✅ Migration complete!');
      return oldDeviceId;
    }

    print('⚠️ Device ID not found for $email');
    return null;
  }

  // Save email on login
  static Future<void> saveEmail(String email) async {
    await _write(_emailKey, email);
    await _macSave(_emailKey, email);
  }

  // Get stored email
  static Future<String?> getStoredEmail() async {
    return await _read(_emailKey) ?? await _macRead(_emailKey);
  }

  // ─── Private helpers ───────────────────────────────────────────────────────

  static Future<String> _getDeviceId() async {
    // Get current user email
    final email = await getStoredEmail();
    if (email == null) {
      return _generateFallbackId();
    }

    // Generate device_id specific to this email
    final emailKey = '${_deviceIdKey}_$email';

    final stored = await _read(emailKey);
    if (stored != null && stored.isNotEmpty) {
      print('📱 Using stored device UUID for $email: $stored');

      // ✅ ALSO save to generic key for MyVpnService compatibility
      await _write(_deviceIdKey, stored);
      await _macSave(_deviceIdKey, stored);

      return stored;
    }

    // Generate new UUID for this email
    print('📱 Generating new device UUID for $email...');
    final newId = _generateFallbackId();

    // ✅ Save to BOTH keys
    await _write(emailKey, newId);
    await _write(_deviceIdKey, newId);
    await _macSave(_deviceIdKey, newId);

    print('📱 ✅ Generated device UUID for $email: $newId');
    return newId;
  }

  /// Generate cryptographically secure device ID
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
