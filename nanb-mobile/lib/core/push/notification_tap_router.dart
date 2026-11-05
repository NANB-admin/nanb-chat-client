import 'dart:async';

import 'local_notifications.dart';

/// Wires notification-tap events from [LocalNotifications] to the app's
/// router. Decoupled from `GoRouter` directly so tests can verify the
/// callback fires without spinning up a router.
///
/// `onTap` receives the `conversationId` payload the wakeup-handler stamped
/// onto the notification.
class NotificationTapRouter {
  NotificationTapRouter({
    required LocalNotifications notifications,
    required void Function(String conversationId) onTap,
  })  : _notifications = notifications,
        _onTap = onTap;

  final LocalNotifications _notifications;
  final void Function(String conversationId) _onTap;
  StreamSubscription<String>? _sub;

  /// Subscribe to taps, then trigger [LocalNotifications.init]. Order is
  /// load-bearing: init() may emit a cold-start launch payload onto the
  /// broadcast tap stream, and broadcast streams drop events with no active
  /// listener. Subscribing first guarantees the launch tap is delivered.
  Future<void> start() async {
    _sub ??= _notifications.conversationTaps.listen(_onTap);
    await _notifications.init();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
