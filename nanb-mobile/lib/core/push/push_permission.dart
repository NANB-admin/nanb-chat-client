/// The OS-level notification permission, as this app sees it.
///
/// Deliberately our own enum rather than the plugin's `AuthorizationStatus`:
/// the settings UI and its tests must not depend on Firebase types, and
/// `provisional` (iOS quiet notifications) is folded into [granted] because it
/// still lets a wakeup through — the only distinction that matters here is
/// whether the OS will deliver.
enum PushPermission {
  /// The OS will deliver notifications (includes iOS provisional/quiet).
  granted,

  /// The user refused. On iOS this is TERMINAL for in-app prompting — the
  /// system never shows the dialog twice, so the only route back is the app's
  /// entry in system settings.
  denied,

  /// Never asked. A prompt will still appear, so offering "Turn on" in-app
  /// works.
  notDetermined,

  /// Couldn't be read — typically Firebase isn't initialized because the
  /// in-app push pref is off. Distinct from [denied] on purpose: reporting it
  /// as denied would blame the OS for something the user can fix in-app.
  unknown,
}
