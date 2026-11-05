import 'dart:async';

import 'models/web_db_write.dart';
import 'web_db_store.dart';

/// Coalesces committed writes and hands them to a [WebDbStore] in batches, so a
/// burst of message inserts becomes ONE backend transaction. Later writes to the
/// same (table, key) replace earlier ones. Batches reach the store strictly in
/// order.
class WebWriteQueue {
  WebWriteQueue(this._store, {this.delay = const Duration(milliseconds: 25)});

  final WebDbStore _store;

  /// How long a first write waits for company before the batch is flushed.
  final Duration delay;

  final Map<String, WebDbWrite> _pending = {};
  Timer? _timer;
  Future<void> _tail = Future<void>.value();

  /// The most recent backend failure of a timer-driven flush (cleared by a
  /// successful flush). Explicit [flush] calls rethrow instead.
  Object? lastError;

  void enqueue(Iterable<WebDbWrite> writes) {
    for (final w in writes) {
      final id = '${w.table}\u0000${w.key}';
      // Remove first so the entry moves to the end: replay order stays the
      // order of the LAST write to each key.
      _pending.remove(id);
      _pending[id] = w;
    }
    if (_pending.isEmpty || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(flush().catchError((Object e) {
        lastError = e;
      }));
    });
  }

  /// Writes everything pending to the store and waits for it (and for any batch
  /// already in flight) to land.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final batch = _pending.values.toList(growable: false);
    _pending.clear();
    if (batch.isNotEmpty) {
      _tail = _tail.then((_) => _store.applyWrites(batch));
    }
    final done = _tail;
    // Keep the chain alive after a failure so later batches still run.
    _tail = done.catchError((Object _) {});
    return done.then((_) {
      lastError = null;
    });
  }

  /// Drops everything pending and wipes the store, after any in-flight batch.
  Future<void> clearAll({bool destroy = false}) {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _tail = _tail.then((_) => destroy ? _store.destroy() : _store.clear());
    final done = _tail;
    _tail = done.catchError((Object _) {});
    return done;
  }
}
