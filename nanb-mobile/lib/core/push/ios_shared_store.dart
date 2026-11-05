import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../models/nse_receipt_outcome.dart';
import '../secure_storage/secure_storage.dart';

/// Mirrors the handful of values the iOS Notification Service Extension needs
/// into the shared **App Group** container, via the native
/// `nanb.app/shared_store` channel (`ios/Runner/SharedStoreChannel.swift`).
///
/// The extension is a separate process that can't read the app's keychain, so
/// it reads these from the App Group file instead (`NseSharedStore`). No-op off
/// iOS. Best-effort: a failure just means the NSE can't send a closed-app
/// "delivered" receipt for now (the foreground catchup is the backstop).
class IosSharedStore {
  static const MethodChannel _channel = MethodChannel('nanb.app/shared_store');

  /// The SecureStorage keys the NSE reads to build the sealed delivered
  /// receipt. MUST stay in sync with `SealedReceiptSender` (Swift):
  /// X25519 private key, Ed25519 identity seed, the per-peer-device seal-keys
  /// directory, the blocked-conversation set, the server base URL, and the
  /// built-in Tor pref — the last so the NSE can SKIP the clearnet receipt when
  /// Tor is on (mirroring the Dart background isolate's
  /// `ApiClientDio.createForBackgroundIsolate` rule; Tor is opt-in, so only an
  /// explicit `true` suppresses the clearnet send).
  static const List<String> mirroredKeys = [
    'crypto.identity.x25519_priv.b64',
    'crypto.identity.seed.b64',
    'delivery.peer_seal_keys',
    'push.blocked_convos',
    'pref.server_url',
    'pref.built_in_tor_enabled',
  ];

  /// Reads [mirroredKeys] from [storage] and writes them to the App Group
  /// container. Call when those values may have changed and before the app can
  /// be backgrounded (app start, app pause, after a receive updates peer keys).
  static Future<void> sync(SecureStorage storage) async {
    if (!Platform.isIOS) return;
    final map = <String, String>{};
    for (final key in mirroredKeys) {
      final value = await storage.getString(key);
      if (value != null && value.isNotEmpty) map[key] = value;
    }
    if (map.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('write', map);
    } catch (_) {/* best-effort; never block the app on this */}
  }

  /// The outcome of the extension's LAST closed-app delivered-receipt attempt,
  /// or null off iOS / before it has ever run.
  ///
  /// The extension has no console on a store build and every failure there is
  /// silent by design, so this is how the app can report which step it reached
  /// (see [NseReceiptOutcome]) without a special debug build.
  static Future<NseReceiptOutcome?> lastReceiptOutcome() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMethod<String>('readLastReceipt');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return NseReceiptOutcome.fromJson(decoded);
    } catch (_) {
      return null; // channel absent (older build) or unreadable
    }
  }
}
