import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// Durable per-envelope failure counter, so an envelope that can never be
/// processed is eventually dropped instead of re-draining forever.
///
/// The receive path already had this idea — count failures, ack+drop as a
/// poison pill past a threshold — but the counters lived in plain in-memory
/// maps. They reset to zero on every app start, and a poison envelope
/// characteristically fails ONCE PER LAUNCH: catchup hands it over, it fails,
/// the count goes 0 -> 1, and the process dies before it can ever reach the
/// threshold. So the threshold was unreachable and the envelope re-drained on
/// every launch, permanently.
///
/// Measured on-device 2026-08-22: 24 sealed MLS envelopes from the previous day
/// were re-fetched and re-decrypted on every single launch, ~900ms of a 1.4s
/// catchup spent re-failing the same messages. That tax grows as poison
/// accumulates, so a device gets slower the longer it lives.
///
/// Bounded and best-effort: losing the map costs one more redelivery round, and
/// never a message — a count that is too LOW only delays the drop.
class EnvelopeRetryLog {
  EnvelopeRetryLog({
    required SecureStorage storage,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final int _maxEntries;

  static const String storageKey = 'receive.envelope_failures';

  /// Enough to cover a large poison backlog without letting the map grow
  /// without bound. Oldest-inserted entries are evicted first; an evicted
  /// envelope simply starts counting again.
  static const int _defaultMaxEntries = 500;

  /// envelopeId -> consecutive failures. Insertion-ordered (Dart Map), so
  /// eviction drops the oldest.
  final Map<String, int> _counts = {};
  bool _loaded = false;
  Future<void>? _pendingWrite;
  bool _dirty = false;

  /// Ids already counted in the current delivery pass; null outside a pass.
  Set<String>? _countedThisPass;

  /// Starts one delivery pass (a catchup drain). Until [endPass], each envelope
  /// counts at most once, however many layers report it. The receiver and the
  /// drain's backstop both report the same undecryptable envelope, and counting
  /// both spent the redelivery budget twice as fast: a message was destroyed on
  /// the third reconnect, not the fifth.
  void beginPass() => _countedThisPass = <String>{};

  /// Ends the pass started by [beginPass].
  void endPass() => _countedThisPass = null;

  /// Total failures recorded this session — lets a caller report how many
  /// envelopes failed SILENTLY inside the receivers, which the catchup drain
  /// cannot otherwise see (the receivers swallow their own decrypt errors, so
  /// the drain counts them as successes).
  int get failuresRecorded => _failuresRecorded;
  int _failuresRecorded = 0;

  /// Records one failure for [envelopeId] and returns its new running total.
  Future<int> recordFailure(String envelopeId) async {
    if (envelopeId.isEmpty) return 0;
    await _ensureLoaded();
    final pass = _countedThisPass;
    if (pass != null && !pass.add(envelopeId)) {
      return _counts[envelopeId] ?? 0;
    }
    _failuresRecorded++;
    final n = (_counts[envelopeId] ?? 0) + 1;
    _counts[envelopeId] = n;
    while (_counts.length > _maxEntries) {
      _counts.remove(_counts.keys.first);
    }
    _dirty = true;
    await _flush();
    return n;
  }

  /// Forgets [envelopeId] — it succeeded, or was acked and dropped, so its
  /// count must not count against a future envelope that reuses the id.
  Future<void> forget(String envelopeId) async {
    await _ensureLoaded();
    if (_counts.remove(envelopeId) == null) return;
    _dirty = true;
    await _flush();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((k, v) {
        if (v is int) _counts[k] = v;
      });
    } catch (_) {
      // Unreadable map degrades to "start counting again" — one more
      // redelivery round, never a lost message.
    }
  }

  /// Coalesces concurrent writes: a drain records failures in bursts and must
  /// not pay a storage round trip per envelope.
  Future<void> _flush() async {
    if (_pendingWrite != null) return;
    final write = _write();
    _pendingWrite = write;
    try {
      await write;
    } finally {
      _pendingWrite = null;
    }
    if (_dirty) await _flush();
  }

  Future<void> _write() async {
    _dirty = false;
    try {
      await _storage.putString(storageKey, jsonEncode(_counts));
    } catch (_) {/* best-effort; the next failure retries it */}
  }
}
