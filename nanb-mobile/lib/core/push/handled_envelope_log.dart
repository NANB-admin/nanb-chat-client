import 'dart:collection';
import 'dart:convert';

import '../secure_storage/secure_storage.dart';

/// A bounded window of envelope ids the FOREGROUND app has already consumed,
/// mirrored where the FCM background isolate can read it.
///
/// A wakeup push is sent for every envelope regardless of whether the live
/// WebSocket already delivered it — deliberately, because a backgrounded iOS
/// app keeps a socket registered that the OS has suspended, so trusting
/// "delivered" meant no notification at all. The safety argument for that was
/// that pushes are data-only and a FOREGROUND app displays nothing.
///
/// That holds only while the app STAYS foreground. The push still sits in FCM's
/// queue, and the moment the user closes the app it is handed to
/// `onBackgroundMessage`, which posts "New message" for something they already
/// read on screen — the "open the app, close it, get a phantom notification"
/// report. The window between reading and closing is exactly when this happens,
/// which is why it looks so reliably like a consequence of closing the app.
///
/// So the foreground records what it consumed and the isolate checks that set
/// before raising a banner. Deliberately NOT a network lookup: the isolate must
/// surface a notification before doing any I/O (on a Tor device a cold circuit
/// can block for tens of seconds, which is what once delayed call rings past
/// the point of usefulness), so this has to be answerable from local state.
class HandledEnvelopeLog {
  HandledEnvelopeLog({
    required SecureStorage storage,
    int maxEntries = _defaultMaxEntries,
  })  : _storage = storage,
        _maxEntries = maxEntries;

  final SecureStorage _storage;
  final int _maxEntries;

  /// Storage key shared with the background isolate.
  static const String storageKey = 'push.handled_envelopes';

  /// How many ids to keep. Enough to cover a catchup batch plus the pushes that
  /// can still be in flight for them, small enough that the mirror stays a
  /// cheap write on the receive path.
  static const int _defaultMaxEntries = 500;

  /// Newest last, so trimming drops the oldest.
  final Queue<String> _ids = Queue<String>();
  bool _loaded = false;

  /// Serialises writes: the receive path acks in bursts, and without this a
  /// catchup batch would queue one storage round-trip per envelope.
  Future<void>? _pendingWrite;
  bool _dirty = false;

  /// Records [envelopeIds] as consumed and mirrors the window for the isolate.
  /// Best-effort — a lost write costs one phantom banner, never a message.
  Future<void> record(Iterable<String> envelopeIds) async {
    if (envelopeIds.isEmpty) return;
    await _ensureLoaded();
    var added = false;
    for (final id in envelopeIds) {
      if (id.isEmpty || _ids.contains(id)) continue;
      _ids.addLast(id);
      added = true;
    }
    if (!added) return;
    while (_ids.length > _maxEntries) {
      _ids.removeFirst();
    }
    _dirty = true;
    await _flush();
  }

  /// Reads the mirrored window. Called from the background isolate, which has
  /// no access to the foreground's in-memory state.
  static Future<Set<String>> read(SecureStorage storage) async {
    try {
      final raw = await storage.getString(storageKey);
      if (raw == null || raw.isEmpty) return const {};
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      // Unreadable mirror degrades to the old behaviour (a possible phantom
      // banner), never to a suppressed real one.
      return const {};
    }
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    // Carry the previous run's window across a restart — a push queued before
    // the app was killed is delivered after it relaunches.
    _ids.addAll(await read(_storage));
    while (_ids.length > _maxEntries) {
      _ids.removeFirst();
    }
  }

  /// Coalesces concurrent writes: while one is in flight the rest just mark the
  /// window dirty, and a single follow-up write persists the latest state.
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
      await _storage.putString(storageKey, jsonEncode(_ids.toList()));
    } catch (_) {
      // Best-effort mirror; the next ack retries it.
    }
  }
}
