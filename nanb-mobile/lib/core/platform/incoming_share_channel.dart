import 'package:flutter/services.dart';

import '../models/incoming_share.dart';

/// Pulls content another app sent us through the OS share sheet ("Share via
/// Chat" in YouTube / Photos / Safari / a file manager).
///
/// PULL, not push. Both platforms stash the payload natively and hand it over
/// only when Dart asks:
///   * Android — `MainActivity` captures the `ACTION_SEND` intent in
///     `onCreate` / `onNewIntent` and copies the streams into the app cache on
///     a worker thread when this channel is called.
///   * iOS — the share extension is a SEPARATE PROCESS that cannot talk to the
///     running app, so it writes the payload into the shared App Group
///     container and merely foregrounds us; `IncomingShareChannel.swift` reads
///     that file here.
///
/// A pull keeps both platforms on ONE delivery path (checked on cold start and
/// on every resume — see `NanbApp`) and makes the hand-off idempotent: a share
/// is consumed exactly once because [takePending] clears the native stash as it
/// reads it. It also means a share that arrives while the app is force-closed
/// (iOS) still lands, since nothing had to be listening at the time.
class IncomingShareChannel {
  const IncomingShareChannel();

  static const MethodChannel _channel =
      MethodChannel('nanb.app/incoming_share');

  /// Returns the pending share and CLEARS it natively, so the same payload is
  /// never delivered twice. Null when nothing is pending — the overwhelming
  /// majority of calls, since this runs on every foreground.
  Future<IncomingShare?> takePending() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('takePending');
      return IncomingShare.tryParse(raw);
    } catch (_) {
      // Channel absent (platform without the native half) or a native read
      // failure. A share we can't collect is dropped, never fatal.
      return null;
    }
  }
}
