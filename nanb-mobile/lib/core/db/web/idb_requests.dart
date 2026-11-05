import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The only place IndexedDB's callback style is bridged to Futures.
abstract final class IdbRequests {
  /// Completes with the request's result, or errors with its DOMException.
  static Future<JSAny?> result(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      done.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      done.completeError(StateError('IndexedDB: ${request.error?.message}'));
    }).toJS;
    return done.future;
  }

  /// Completes when [tx] commits; errors if it aborts or fails.
  static Future<void> committed(web.IDBTransaction tx) {
    final done = Completer<void>();
    tx.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB: ${tx.error?.message}'));
      }
    }).toJS;
    tx.onabort = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB abort: ${tx.error?.message}'));
      }
    }).toJS;
    return done.future;
  }
}
