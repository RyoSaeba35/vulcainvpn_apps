import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:io';
import '../colors.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Initialize notifications
  static Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        // User tapped notification - app will open via MainActivity intent
      },
    );

    _initialized = true;
  }

  // Show VPN disconnected notification
  static Future<void> showVpnDisconnectedNotification({
    required String reason,
    required String message,
  }) async {
    if (!Platform.isAndroid) return;

    await initialize();

    const androidDetails = AndroidNotificationDetails(
      'vpn_status',
      'VPN Status',
      channelDescription: 'Notifications about VPN connection status',
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      ongoing: false,
      icon: '@mipmap/ic_launcher',
      color: MyColors.myOrange,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    String title = 'VPN Disconnected';
    String body = message;

    // Customize based on reason
    if (reason == 'service_killed') {
      title = 'VPN Service Stopped';
      body = 'Android stopped your VPN. Tap to reconnect.';
    } else if (reason == 'permission_revoked') {
      title = 'VPN Permission Revoked';
      body = 'VPN permission was removed. Tap to restore.';
    } else if (reason == 'vpn_broken') {
      title = 'VPN Connection Lost';
      body = 'Could not reconnect automatically. Tap to try again.';
    } else if (reason == 'subscription_expired') {
      title = 'Subscription Expired';
      body = 'Your VPN subscription has expired. Tap to renew.';
    }

    await _notifications.show(
      1001, // Notification ID
      title,
      body,
      notificationDetails,
    );
  }

  // Cancel all notifications
  static Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }
}
