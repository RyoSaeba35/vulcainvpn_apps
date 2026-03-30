import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';  // ✅ FIX #6: For Random.secure()
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ✅ SECURITY FIX #3: Encrypt VPN config files before writing to disk
///
/// Prevents credentials from being stolen if someone gains file system access.
/// Uses AES-256-GCM with device-specific encryption keys.
class SecureConfigService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    wOptions: WindowsOptions(
      useBackwardCompatibility: true,
    ),
  );

  static const String _encryptionKeyStorageKey = 'vpn_config_encryption_key';
  static const String _ivStorageKey = 'vpn_config_iv';

  /// Get or generate encryption key for config files
  /// The key is device-specific and stored securely
  static Future<encrypt.Key> _getEncryptionKey() async {
    // Try to get existing key from secure storage
    String? keyBase64 = await _storage.read(key: _encryptionKeyStorageKey);

    if (keyBase64 != null) {
      // Use existing key
      final keyBytes = base64.decode(keyBase64);
      return encrypt.Key(Uint8List.fromList(keyBytes));
    }

    // Generate new 256-bit key
    final key = encrypt.Key.fromSecureRandom(32); // 32 bytes = 256 bits

    // Store it securely
    await _storage.write(
      key: _encryptionKeyStorageKey,
      value: base64.encode(key.bytes),
    );

    return key;
  }

  /// Get or generate initialization vector (IV)
  /// Each device has its own IV for additional security
  static Future<encrypt.IV> _getIV() async {
    String? ivBase64 = await _storage.read(key: _ivStorageKey);

    if (ivBase64 != null) {
      final ivBytes = base64.decode(ivBase64);
      return encrypt.IV(Uint8List.fromList(ivBytes));
    }

    // Generate new 128-bit IV
    final iv = encrypt.IV.fromSecureRandom(16); // 16 bytes = 128 bits

    // Store it securely
    await _storage.write(
      key: _ivStorageKey,
      value: base64.encode(iv.bytes),
    );

    return iv;
  }

  /// Encrypt VPN configuration before writing to disk
  ///
  /// @param configJson The JSON config string to encrypt
  /// @return Base64-encoded encrypted data
  static Future<String> encryptConfig(String configJson) async {
    try {
      final key = await _getEncryptionKey();
      final iv = await _getIV();

      // Create AES-256-GCM encrypter
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );

      // Encrypt the config
      final encrypted = encrypter.encrypt(configJson, iv: iv);

      // Return base64-encoded encrypted data
      return encrypted.base64;
    } catch (e) {
      print('❌ Config encryption failed: $e');
      rethrow;
    }
  }

  /// Decrypt VPN configuration after reading from disk
  ///
  /// @param encryptedBase64 Base64-encoded encrypted data
  /// @return Decrypted JSON config string
  static Future<String> decryptConfig(String encryptedBase64) async {
    try {
      final key = await _getEncryptionKey();
      final iv = await _getIV();

      // Create AES-256-GCM encrypter
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );

      // Decrypt the config
      final encrypted = encrypt.Encrypted.fromBase64(encryptedBase64);
      final decrypted = encrypter.decrypt(encrypted, iv: iv);

      return decrypted;
    } catch (e) {
      print('❌ Config decryption failed: $e');
      rethrow;
    }
  }

  /// Write encrypted config to disk
  ///
  /// @param filePath Where to write the encrypted config
  /// @param configJson The plaintext config to encrypt and write
  static Future<void> writeEncryptedConfig(
    String filePath,
    String configJson,
  ) async {
    try {
      // Encrypt the config
      final encrypted = await encryptConfig(configJson);

      // Write encrypted data to file
      final file = File(filePath);
      await file.writeAsString(encrypted);

      print('✅ Config encrypted and written to: $filePath');
    } catch (e) {
      print('❌ Failed to write encrypted config: $e');
      rethrow;
    }
  }

  /// Read and decrypt config from disk
  ///
  /// @param filePath Where to read the encrypted config from
  /// @return Decrypted JSON config string
  static Future<String> readEncryptedConfig(String filePath) async {
    try {
      // Read encrypted data from file
      final file = File(filePath);
      final encryptedData = await file.readAsString();

      // Decrypt and return
      final decrypted = await decryptConfig(encryptedData);

      print('✅ Config read and decrypted from: $filePath');
      return decrypted;
    } catch (e) {
      print('❌ Failed to read encrypted config: $e');
      rethrow;
    }
  }

  /// Securely delete config file using DoD 5220.22-M standard
  ///
  /// Uses 3-pass overwrite:
  /// - Pass 1: Write 0x00 (zeros)
  /// - Pass 2: Write 0xFF (ones)
  /// - Pass 3: Write cryptographically secure random data
  /// - Finally: Delete file and verify deletion
  ///
  /// @param filePath File to securely delete
  static Future<void> secureDelete(String filePath) async {
    try {
      final file = File(filePath);

      if (!await file.exists()) {
        return; // File doesn't exist, nothing to delete
      }

      // Get file size
      final fileSize = await file.length();

      // ✅ FIX #6: DoD 5220.22-M standard 3-pass overwrite

      // Pass 1: Write zeros (0x00)
      final zerosData = Uint8List(fileSize);
      // Uint8List is already initialized with zeros
      await file.writeAsBytes(zerosData);

      // Pass 2: Write ones (0xFF)
      final onesData = Uint8List(fileSize);
      for (int i = 0; i < fileSize; i++) {
        onesData[i] = 0xFF;
      }
      await file.writeAsBytes(onesData);

      // Pass 3: Write cryptographically secure random data
      final random = Random.secure();  // ✅ FIX #6: Secure random generator
      final randomData = Uint8List(fileSize);
      for (int i = 0; i < fileSize; i++) {
        randomData[i] = random.nextInt(256);
      }
      await file.writeAsBytes(randomData);

      // Finally delete the file
      await file.delete();

      // ✅ FIX #6: Verify deletion was successful
      if (await file.exists()) {
        throw Exception('File still exists after deletion: $filePath');
      }

      print('✅ Config file securely deleted: $filePath');
    } catch (e) {
      print('❌ Failed to securely delete config: $e');
      rethrow;
    }
  }

  /// Clear all encryption keys (use when user logs out)
  static Future<void> clearEncryptionKeys() async {
    try {
      await _storage.delete(key: _encryptionKeyStorageKey);
      await _storage.delete(key: _ivStorageKey);
      print('✅ Encryption keys cleared');
    } catch (e) {
      print('❌ Failed to clear encryption keys: $e');
    }
  }
}

/// SECURITY NOTES:
///
/// 1. ENCRYPTION ALGORITHM:
///    - AES-256-GCM (Galois/Counter Mode)
///    - Provides both encryption AND authentication
///    - Industry standard, used by Signal, WhatsApp, TLS 1.3
///
/// 2. KEY MANAGEMENT:
///    - 256-bit key generated using secure random
///    - Stored in platform secure storage (Keychain/Keystore)
///    - Never written to logs or regular files
///    - Device-specific (different key per device)
///
/// 3. INITIALIZATION VECTOR (IV):
///    - 128-bit IV for GCM mode
///    - Device-specific and stored securely
///    - Prevents pattern analysis across devices
///
/// 4. SECURE DELETION:
///    - 3-pass overwrite with random data
///    - Prevents forensic recovery
///    - Called when VPN disconnects
///
/// 5. ATTACK RESISTANCE:
///    - File theft: ✅ Protected (encrypted)
///    - Forensic recovery: ✅ Protected (secure deletion)
///    - Key theft from storage: ✅ Protected (platform Keychain/Keystore)
///    - Memory dump: ⚠️ Partial (keys in memory during use)
