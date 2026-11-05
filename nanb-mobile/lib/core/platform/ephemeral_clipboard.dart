import 'dart:async';

import 'package:flutter/services.dart';

/// Copies sensitive text to the OS clipboard and schedules it to be wiped after
/// [clearAfter]. Secrets like the recovery phrase (which regenerates the whole
/// account identity) and decrypted message bodies must not linger indefinitely
/// in the shared, cross-app, keyboard-history-captured clipboard.
///
/// The scheduled clear only fires if the clipboard STILL holds exactly what we
/// put there — so we never clobber something the user copied afterwards. Runs as
/// a detached [Future.delayed] (not tied to any widget lifecycle) so it survives
/// the screen being popped. Best-effort: clipboard access can throw on some
/// platforms, and those failures are swallowed.
Future<void> copyEphemeral(
  String text, {
  Duration clearAfter = const Duration(seconds: 60),
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  unawaited(Future<void>.delayed(clearAfter, () async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {/* clipboard unavailable — nothing to clear */}
  }));
}
