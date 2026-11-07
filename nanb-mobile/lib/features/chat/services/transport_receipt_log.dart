import 'dart:async';
import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// Durable record of the outgoing messages whose only "delivered" evidence is a
/// TRANSPORT receipt: the recipient's push handler (iOS notification extension,
/// Android background isolate) or the server saying the envelope landed.
///
/// Those receipts fire before anything is decrypted, so they prove nothing about
/// whether the message can be read. A recipient whose MLS group is gone still
/// sends them, which is how a lost message ended up showing ✓✓ on the sender.
/// [UnconfirmedMessageResender] therefore still treats these as unconfirmed. An
/// end-to-end receipt, sent only after a successful decrypt, clears the mark.
///
/// Bounded and best-effort: losing an entry only means that message counts as
/// confirmed, which is how every message behaved before this log existed.
class TransportReceiptLog {
  TransportReceiptLog({
    required SecureStorage storage,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final int _maxEntries;

  static const String storageKey = 'send.transport_only_receipts';

  /// A resend run looks at no more than the newest 50 messages per chat, so this
  /// comfortably covers normal use. Oldest-inserted entries go first.
  static const int _defaultMaxEntries = 500;

  /// Insertion-ordered (a Dart Map), so eviction drops the oldest.
  final Map<String, bool> _ids = {};
  Future<void>? _loading;
  Future<void>? _pendingWrite;
  bool _dirty = false;

  /// Whether [envelopeId] is delivered on transport evidence alone.
  Future<bool> contains(String envelopeId) async {
    await _ensureLoaded();
    return _ids.containsKey(envelopeId);
  }

  /// Marks [envelopeId] as confirmed by the transport only.
  Future<void> add(String envelopeId) async {
    if (envelopeId.isEmpty) return;
    await _ensureLoaded();
    _ids.remove(envelopeId);
    _ids[envelopeId] = true;
    while (_ids.length > _maxEntries) {
      _ids.remove(_ids.keys.first);
    }
    _dirty = true;
    await _flush();
  }

  /// Clears the mark: the recipient decrypted [envelopeId] and said so.
  Future<void> remove(String envelopeId) async {
    await _ensureLoaded();
    if (_ids.remove(envelopeId) == null) return;
    _dirty = true;
    await _flush();
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
    } catch (_) {/* unreadable: everything counts as confirmed, the old default */}
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
    } catch (_) {/* best-effort; the next change retries it */}
  }
}
