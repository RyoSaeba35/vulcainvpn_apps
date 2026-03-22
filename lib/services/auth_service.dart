// lib/services/auth_service.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class AuthService {
  static const String _baseUrl = 'https://api.vulcainvpn.com/api';
  static const String _tokenKey = 'jwt_token';
  static const String _apiKeyKey = 'api_key';
  static const String _deviceIdKey = 'device_id';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    wOptions: WindowsOptions(),
  );

  // Login — fetches and stores JWT token
  static Future<bool> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        await _storage.write(key: _tokenKey, value: data['token']);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // Logout — clears all stored credentials
  static Future<void> logout() async {
    await _storage.deleteAll();
  }

  // Get stored JWT token
  static Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  // Check if user is logged in
  static Future<bool> isLoggedIn() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return false;

    // Check if token is expired by decoding the payload
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;

      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))
      );

      final exp = payload['exp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      if (exp < now) {
        // Token expired — clear storage
        await _storage.deleteAll();
        return false;
      }
      return true;
    } catch (e) {
      return false;
    }
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
}
