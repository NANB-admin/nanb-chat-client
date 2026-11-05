/// The single reason this device cannot currently be woken by a notification.
///
/// Four independent gates have to line up before a push lands, and to the user
/// they all look like "notifications are on/off". Naming the ONE that is
/// actually blocking is the whole point — a tester who has granted the OS
/// permission and still hears nothing is otherwise stuck, because every screen
/// they can see says notifications are enabled.
///
/// Ordered by how early the gate sits in the chain, so the UI can report the
/// first thing worth fixing rather than a list of everything wrong.
enum PushBlocker {
  /// Nothing is blocking: the OS will deliver and the server holds a token.
  none,

  /// Settings -> Notifications -> "Enable notifications" is off.
  appNotificationsOff,

  /// Settings -> Privacy -> push over Google/FCM is off. Off by DEFAULT for
  /// privacy, which is why this is the most common surprise: a fresh install
  /// contacts Google not at all, so nothing else in the chain can work yet.
  pushOverFcmOff,

  /// The OS permission was never requested (the one-time prompt was dismissed
  /// with "Not now"). An in-app prompt still works.
  osPermissionNotAsked,

  /// The OS permission was refused. On iOS this cannot be re-prompted — the
  /// user has to be sent to the app's entry in system settings.
  osPermissionDenied,

  /// Every toggle is on but no push token reached the server, so it can't
  /// address this device. Usually a transient registration failure that a
  /// retry fixes; on iOS it also happens when APNs never handed Firebase a
  /// device token.
  noTokenRegistered,
}
