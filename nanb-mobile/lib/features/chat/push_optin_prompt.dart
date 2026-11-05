import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/push/fcm_activator.dart';

/// Shows the ONE-TIME push opt-in prompt, if the user hasn't answered it yet and
/// push isn't already on. Safe to call whenever the chat list mounts — it
/// self-gates on `pushPromptSeen` / `pushOverFcmEnabled`.
///
/// Push (Google Firebase Cloud Messaging) is OFF by default for privacy — a
/// fresh install contacts Google not at all. This is where the user makes the
/// choice. On "Turn on":
///   1. flip the pref (so the FCM providers switch on),
///   2. initialize Firebase at runtime via [fcmRuntimeActivator] so it works
///      this session (backstopped by the pref: `main()` re-initializes next
///      launch even if this fails),
///   3. request the OS notification permission directly via the facade (not the
///      flag-gated permission gate, which the stub seam may already have
///      consumed while push was off), and
///   4. register the push token with the server.
/// On "Not now" it only records that the prompt was shown, so it never re-asks.
Future<void> maybeShowPushOptIn(BuildContext context, WidgetRef ref) async {
  // No FCM in a browser (and no Google-push trade-off to explain): never ask.
  if (kIsWeb) return;
  final notifier = ref.read(appPreferencesProvider);
  // Only prompt once prefs are hydrated from storage. Before that `value` is
  // just the defaults, so acting on it could re-prompt a returning user who
  // already answered — and it keeps the prompt out of widget tests (which don't
  // hydrate). In the real app main() hydrates synchronously before first build.
  if (!notifier.hydrated) return;
  final prefs = notifier.value;
  if (prefs.pushPromptSeen || prefs.pushOverFcmEnabled) return;

  final enable = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Turn on notifications?'),
      content: const Text(
        'Get notified of new messages even when Chat is closed.\n\n'
        'Push is delivered by Google (Firebase), which runs outside Tor — when '
        'on, Google sees this device’s IP address and message timing. It never '
        'sees your messages, which stay end-to-end encrypted.\n\n'
        'You can change this anytime in Settings → Privacy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('NOT NOW'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('TURN ON'),
        ),
      ],
    ),
  );

  // Record that we asked, either way, so the prompt never appears again.
  await notifier.setPushPromptSeen(true);
  if (enable != true) return;

  await notifier.setPushOverFcmEnabled(true);
  // Bring Firebase up now so push works this session. Backstopped by the pref —
  // even if this throws, main() initializes FCM on the next launch.
  try {
    await fcmRuntimeActivator?.call();
  } catch (_) {/* backstopped by next-launch init */}
  // Request the OS notification permission directly (Firebase is up now). This
  // bypasses the flag-gated NotificationPermissionGate, whose one-shot flag the
  // stub seam may already have consumed while push was off this session.
  try {
    await ref.read(firebaseMessagingFacadeProvider).requestPermission();
  } catch (_) {/* Firebase unavailable → no-op; token registration still tries */}
  // The pref is on now, so the token provider yields a real FCM token: register
  // it with the server. Best-effort (the registrar swallows failures).
  unawaited(ref.read(pushTokenRegistrarProvider).bootstrap());
}
