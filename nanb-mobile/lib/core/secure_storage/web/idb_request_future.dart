import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Adapts an IndexedDB request (callback style) to a [Future] of its result.
///
/// The result is returned as a [JSAny]; callers cast it to the specific
/// interop type they expect (for example `web.IDBDatabase`).
Future<JSAny?> idbRequestFuture(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) {
    completer.complete(request.result);
  }).toJS;
  request.onerror = ((web.Event _) {
    completer.completeError(
      StateError('IndexedDB request failed: ${request.error?.message}'),
    );
  }).toJS;
  return completer.future;
}

/// Completes when [tx] has fully committed (its writes are durable), or fails
/// if it aborts. A request succeeding is NOT the same as the data being
/// committed, so writers await this before reporting success.
Future<void> idbTransactionDone(web.IDBTransaction tx) {
  final completer = Completer<void>();
  tx.oncomplete = ((web.Event _) => completer.complete()).toJS;
  tx.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('IndexedDB transaction failed: ${tx.error?.message}'),
      );
    }
  }).toJS;
  tx.onabort = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError('IndexedDB transaction aborted: ${tx.error?.message}'),
      );
    }
  }).toJS;
  return completer.future;
}
