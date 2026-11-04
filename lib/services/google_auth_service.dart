import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';

/// "Continue with Google" on Android (google_sign_in 7.x, Credential Manager).
/// Returns a Google ID token for the backend to verify; never stores anything.
class GoogleAuthService {
  /// OAuth **Web** client ID from Google Cloud (project vulcainvpn).
  /// It is public (it ends up in every ID token), not a secret.
  static const String serverClientId =
      '673245002373-27bg8jh8rrdtq5gva60rml7vbld3d3cc.apps.googleusercontent.com';

  static bool get isSupported => Platform.isAndroid;

  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _initialized = true;
  }

  /// Shows the Google account picker. Returns the ID token, or null if the
  /// user cancelled. Throws on real errors.
  static Future<String?> getIdToken() async {
    if (!isSupported) return null;
    await _ensureInitialized();

    try {
      final account = await GoogleSignIn.instance.authenticate(scopeHint: const ['email']);
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Forget the chosen account so the picker shows again next time.
  static Future<void> signOut() async {
    if (!isSupported || !_initialized) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
