import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A tiny, content-free diary of WebSocket lifecycle events: when the socket
/// came up, what took it down (close code), and which in-app trigger forced a
/// reconnect. Release builds silence every `print`, so without this the cause
/// of a flapping "Connecting..." banner is invisible on the device that has it.
///
/// Records event KINDS and timestamps only - never message content, ids or
/// peers. Persisted to a small file so a suspended-and-killed app keeps the
/// trail leading up to the kill; capped so it can't grow.
class ConnectionLog {
  ConnectionLog._();

  static final ConnectionLog instance = ConnectionLog._();

  static const int _maxLines = 400;
  static const int _maxFileBytes = 64 * 1024;
  static const String _fileName = 'connection_log.txt';

  final List<String> _lines = <String>[];
  File? _file;
  Future<void>? _resolving;
  Future<void> _writes = Future<void>.value();

  /// Appends one event. Never throws - diagnostics must not cost a connection.
  void add(String event) {
    final stamp = DateTime.now().toUtc().toIso8601String().substring(11, 23);
    final line = '$stamp $event';
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
    _writes = _writes.then((_) => _append(line)).catchError((Object _) {});
  }

  /// The persisted trail (previous runs included), oldest first.
  Future<String> read() async {
    await _writes;
    final file = await _resolveFile();
    if (file == null || !file.existsSync()) return _lines.join('\n');
    final all = (await file.readAsString()).split('\n')
      ..removeWhere((l) => l.isEmpty);
    final tail =
        all.length > _maxLines ? all.sublist(all.length - _maxLines) : all;
    return tail.join('\n');
  }

  Future<void> _append(String line) async {
    final file = await _resolveFile();
    if (file == null) return;
    await file.writeAsString('$line\n', mode: FileMode.append);
    // Rewrite from memory once the file has clearly outgrown the cap.
    if (file.lengthSync() > _maxFileBytes) {
      await file.writeAsString('${_lines.join('\n')}\n');
    }
  }

  Future<File?> _resolveFile() async {
    _resolving ??= () async {
      try {
        final dir = await getApplicationSupportDirectory();
        _file = File('${dir.path}/$_fileName');
      } catch (_) {
        _file = null; // no storage (tests): in-memory only
      }
    }();
    await _resolving;
    return _file;
  }
}
