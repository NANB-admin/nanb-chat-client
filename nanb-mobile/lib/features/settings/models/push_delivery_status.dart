import '../../../core/push/push_permission.dart';
import 'push_blocker.dart';

/// A snapshot of every gate a notification has to pass to reach this device.
///
/// Exists because "notifications don't work" has four independent causes that
/// are indistinguishable from any screen the user can currently see, and the
/// support answer differs completely between them.
class PushDeliveryStatus {
  const PushDeliveryStatus({
    required this.appNotificationsEnabled,
    required this.pushOverFcmEnabled,
    required this.permission,
    required this.hasServerToken,
  });

  /// Settings -> Notifications -> "Enable notifications".
  final bool appNotificationsEnabled;

  /// Settings -> Privacy -> push over Google (FCM). Off by default.
  final bool pushOverFcmEnabled;

  /// The OS-level permission.
  final PushPermission permission;

  /// Whether a push token is registered with the server. Null while no
  /// registration has been attempted yet this session — "not known", which must
  /// not be rendered as failure.
  final bool? hasServerToken;

  /// True when a notification can actually be delivered right now.
  bool get deliverable => blocker == PushBlocker.none;

  /// The FIRST gate in the chain that is blocking delivery.
  ///
  /// Order matters: an earlier gate being off is why the later ones look
  /// broken. With push-over-FCM off, for instance, Firebase is never
  /// initialized, so the permission reads [PushPermission.unknown] and no token
  /// exists — reporting either of those would send the user chasing the wrong
  /// thing.
  PushBlocker get blocker {
    if (!appNotificationsEnabled) return PushBlocker.appNotificationsOff;
    if (!pushOverFcmEnabled) return PushBlocker.pushOverFcmOff;
    switch (permission) {
      case PushPermission.denied:
        return PushBlocker.osPermissionDenied;
      case PushPermission.notDetermined:
        return PushBlocker.osPermissionNotAsked;
      case PushPermission.granted:
      case PushPermission.unknown:
        // `unknown` reaching here means the toggles are on but Firebase still
        // couldn't be read. Don't accuse the OS — fall through to the token
        // check, which is the actionable signal.
        break;
    }
    // Null = no registration attempted yet. Not a failure, so don't report one.
    if (hasServerToken == false) return PushBlocker.noTokenRegistered;
    return PushBlocker.none;
  }
}
