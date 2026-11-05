/// Runtime FCM activation hook.
///
/// Firebase/FCM push is OFF by default (opt-in) — see
/// [AppPreferences.pushOverFcmEnabled]. `main()` only initializes Firebase at
/// boot when push is already enabled, so when the user opts in mid-session (the
/// first-launch prompt or Settings → Privacy) Firebase still needs to be brought
/// up. `main()` assigns this hook at startup so the opt-in flow can run that same
/// initialization on demand — push then works without an app restart.
///
/// It is a top-level function pointer (not a provider) so it can reference the
/// top-level, `@pragma('vm:entry-point')` background message handler that lives
/// in `main.dart`. Null until `main()` wires it (e.g. in widget tests).
Future<void> Function()? fcmRuntimeActivator;
