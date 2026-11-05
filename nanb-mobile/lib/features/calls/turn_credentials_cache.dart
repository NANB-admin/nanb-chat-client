import 'dart:convert';

import '../../core/models/turn_credentials.dart';
import '../../core/secure_storage/secure_storage.dart';

/// Persists the TURN credentials from `GET /turn/credentials` across calls — and
/// across process death — so the call-setup path doesn't refetch them.
///
/// The server issues these with a **12-hour** TTL (`NANB_TURN_TTL_SECONDS`,
/// default 43200), but every call used to refetch them anyway: a Tor round-trip
/// with up to 3 attempts and backoff ([loadCallIceConfig]), sitting dead-last on
/// the accept→connected path — after the WS connect and the catchup drain, i.e.
/// exactly where a cold circuit is slowest and the connect deadline is tightest.
/// Persisting (not just memoising) is the point: a call answered from a push
/// starts a FRESH isolate, so an in-memory cache would miss on the one path that
/// actually hurts.
///
/// **The margin is the safety-critical part.** coturn re-authenticates the
/// ephemeral username on every allocation Refresh and CreatePermission for the
/// life of a call, so a credential that expires MID-call doesn't just fail the
/// next setup — it strands the relay permission and drops the media of a call
/// that's already up. [_minRemaining] therefore has to cover the longest call we
/// expect, not merely the setup. An hour against a 12-hour TTL still leaves ~11h
/// of cache hits, so the margin costs essentially nothing.
class TurnCredentialsCache {
  TurnCredentialsCache({
    required SecureStorage storage,
    DateTime Function()? clock,
  })  : _storage = storage,
        _now = clock ?? DateTime.now;

  final SecureStorage _storage;
  final DateTime Function() _now;

  /// Versioned so a future change to the stored shape can't be misread as valid
  /// — an unknown/!parseable entry is simply a miss (see [_read]).
  static const String storageKey = 'turn.credentials.v1';

  /// Only reuse a credential with at least this long to live. See the class doc:
  /// this bounds the longest call a cached credential must survive, not setup.
  static const Duration _minRemaining = Duration(hours: 1);

  /// Cached credentials if still comfortably valid, else [fetch] (and store it).
  ///
  /// A cache miss behaves exactly as before this class existed, so every failure
  /// mode here degrades to "refetch over Tor" rather than breaking the call.
  Future<TurnCredentials> get(Future<TurnCredentials> Function() fetch) async {
    final cached = await _read();
    if (cached != null) return cached;
    final fresh = await fetch();
    await _write(fresh);
    return fresh;
  }

  /// Drops the cached credential. The coturn username embeds the issuing
  /// account id, so this MUST run on account switch/wipe — otherwise the next
  /// account would relay its calls under the previous user's identity.
  Future<void> clear() async {
    try {
      await _storage.delete(storageKey);
    } catch (_) {/* best-effort — a stale entry still expires on its own */}
  }

  Future<TurnCredentials?> _read() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        json['expiresAtMs'] as int,
        isUtc: true,
      );
      if (expiresAt.difference(_now().toUtc()) < _minRemaining) return null;
      return TurnCredentials(
        urls: (json['urls'] as List).map((e) => e as String).toList(),
        username: json['username'] as String,
        credential: json['credential'] as String,
        ttlSeconds: json['ttl'] as int,
      );
    } catch (_) {
      return null; // absent / corrupt / older shape → treat as a miss
    }
  }

  Future<void> _write(TurnCredentials c) async {
    try {
      final expiresAt = _now().toUtc().add(Duration(seconds: c.ttlSeconds));
      await _storage.putString(
        storageKey,
        jsonEncode({
          'urls': c.urls,
          'username': c.username,
          'credential': c.credential,
          'ttl': c.ttlSeconds,
          'expiresAtMs': expiresAt.millisecondsSinceEpoch,
        }),
      );
    } catch (_) {/* best-effort — worst case the next call refetches */}
  }
}
