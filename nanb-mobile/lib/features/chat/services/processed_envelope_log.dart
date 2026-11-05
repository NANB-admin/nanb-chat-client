import 'dart:async';
import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// Durable record of the MLS application envelopes this device has already
/// DECRYPTED, so a redelivery of one is acked and dropped instead of being
/// decrypted a second time.
///
/// MLS (like the ratchet) is forward-secret: CoreCrypto consumes the message key
/// on the first decrypt and refuses the same ciphertext afterwards. An envelope
/// is redelivered whenever its ack never landed — the app was suspended or
/// killed between decrypt and ack, or the ack request failed on a bad network —
/// and that second decrypt throws exactly like a real split-brain failure.
/// `MlsReceiver` counts those failures and, at a streak of three, tears the
/// (healthy) group down and rebuilds it. The rebuild strands whatever was in
/// flight, which comes back unacked, which fails again: a loop of Welcomes in
/// which the recipient gets the push but never the message.
///
/// Bounded and best-effort: losing the set only costs the old behaviour for the
/// envelopes that fell out of it, never a message.
class ProcessedEnvelopeLog {
  ProcessedEnvelopeLog({
    required SecureStorage storage,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final int _maxEntries;

  static const String storageKey = 'receive.processed_envelopes';

  /// Redeliveries arrive within one catchup of the original, so this only has
  /// to outlast a burst of unacked traffic. Oldest-inserted entries go first.
  static const int _defaultMaxEntries = 1000;

  /// Insertion-ordered (a Dart Map), so eviction drops the oldest.
  final Map<String, bool> _ids = {};
  Future<void>? _loading;
  Future<void>? _pendingWrite;
  bool _dirty = false;

  /// Whether [envelopeId] was already decrypted by this device.
  Future<bool> contains(String envelopeId) async {
    if (envelopeId.isEmpty) return false;
    await _ensureLoaded();
    return _ids.containsKey(envelopeId);
  }

  /// Records [envelopeId] as decrypted. The write is detached: marking is on the
  /// hot path of every received message and must not slow a catchup drain.
  Future<void> add(String envelopeId) async {
    if (envelopeId.isEmpty) return;
    await _ensureLoaded();
    _ids.remove(envelopeId);
    _ids[envelopeId] = true;
    while (_ids.length > _maxEntries) {
      _ids.remove(_ids.keys.first);
    }
    _dirty = true;
    unawaited(_flush());
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await _storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      for (final id in decoded) {
        if (id is String && !_ids.containsKey(id)) _ids[id] = true;
      }
    } catch (_) {
      // Unreadable set degrades to "treat everything as new" — the old
      // behaviour, never a lost message.
    }
  }

  /// Coalesces concurrent writes into one in-flight write plus a trailing one.
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
      await _storage.putString(storageKey, jsonEncode(_ids.keys.toList()));
    } catch (_) {/* best-effort; the next add retries it */}
  }
}
