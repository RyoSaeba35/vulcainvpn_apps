import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';

/// Android App Links: https://www.vulcainvpn.com/users/confirmation?confirmation_token=...
/// opens the app (when installed) instead of the browser. Desktop keeps
/// opening these links on the website.
class DeepLinkService {
  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri>? _subscription;
  static final Set<String> _handledTokens = {};

  static bool get isSupported => Platform.isAndroid;

  /// Calls [onConfirmationToken] once per confirmation link, including the
  /// link that launched the app (app_links emits it on the stream).
  static void listen(void Function(String token) onConfirmationToken) {
    if (!isSupported) return;

    _subscription?.cancel();
    _subscription = _appLinks.uriLinkStream.listen(
      (uri) {
        final token = confirmationToken(uri);
        if (token == null || _handledTokens.contains(token)) return;
        _handledTokens.add(token);
        onConfirmationToken(token);
      },
      onError: (e) => print('⚠️ Deep link error: $e'),
    );
  }

  static void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  static String? confirmationToken(Uri uri) {
    if (!uri.path.startsWith('/users/confirmation')) return null;
    final token = uri.queryParameters['confirmation_token'];
    return (token == null || token.isEmpty) ? null : token;
  }
}
