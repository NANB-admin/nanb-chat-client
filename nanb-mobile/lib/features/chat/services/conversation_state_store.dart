import 'dart:async';
import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';
import '../models/chat_background_override.dart';
import '../models/conversation_state_field.dart';
import '../models/field_version.dart';

/// Per-conversation sync metadata, kept in ONE SecureStorage JSON map (no
/// database column, so no schema migration):
///
/// ```
/// { "<conversationId>": {
///     "v":  { "<field>": [timestampMs, "deviceId"] },   // LWW versions
///     "w":  { "readUpToMs": 123, "clearedAtMs": 456 },  // monotone watermarks
///     "bg": "default" | "<preset>" | "photo:<path>"     // background override
/// } }
/// ```
/// Reads are synchronous once [load] has completed (the UI reads the background
/// override while building); writes are serialized.
class ConversationStateStore {
  ConversationStateStore(this._storage, {String key = storageKey})
      : _key = key;

  static const String storageKey = 'conversation.state_sync';

  final SecureStorage _storage;
  final String _key;

  final Map<String, Map<String, FieldVersion>> _versions = {};
  final Map<String, Map<String, int>> _watermarks = {};
  final Map<String, ChatBackgroundOverride> _backgrounds = {};
  Future<void>? _loading;
  bool _loaded = false;
  Future<void> _writeChain = Future<void>.value();

  bool get isLoaded => _loaded;

  /// Loads the persisted map once; later calls share the same future.
  Future<void> load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final raw = await _storage.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) _ingest(decoded);
      }
    } catch (_) {/* unreadable -> start empty; LWW re-converges */}
    _loaded = true;
  }

  void _ingest(Map<dynamic, dynamic> root) {
    for (final e in root.entries) {
      final id = e.key;
      final entry = e.value;
      if (id is! String || entry is! Map) continue;
      final v = entry['v'];
      if (v is Map) {
        for (final f in v.entries) {
          final pair = f.value;
          if (f.key is String &&
              pair is List &&
              pair.length == 2 &&
              pair[0] is int &&
              pair[1] is String) {
            (_versions[id] ??= {})[f.key as String] =
                FieldVersion(pair[0] as int, pair[1] as String);
          }
        }
      }
      final w = entry['w'];
      if (w is Map) {
        for (final f in w.entries) {
          if (f.key is String && f.value is int) {
            (_watermarks[id] ??= {})[f.key as String] = f.value as int;
          }
        }
      }
      final bg = entry['bg'];
      if (bg is String) _backgrounds[id] = ChatBackgroundOverride.fromStorage(bg);
    }
  }

  FieldVersion? versionOf(String conversationId, ConversationStateField f) =>
      _versions[conversationId]?[f.wire];

  /// The stored watermark for [f] (`readUpToMs` / `clearedAtMs`), 0 if none.
  int watermarkOf(String conversationId, ConversationStateField f) =>
      _watermarks[conversationId]?[f.wire] ?? 0;

  /// The per-chat background override (use-default when none is stored).
  ChatBackgroundOverride backgroundOf(String conversationId) =>
      _backgrounds[conversationId] ?? const ChatBackgroundOverride.useDefault();

  /// Fields that have a stored version for [conversationId].
  Map<ConversationStateField, FieldVersion> versionsFor(String conversationId) {
    final out = <ConversationStateField, FieldVersion>{};
    final stored = _versions[conversationId];
    if (stored == null) return out;
    for (final e in stored.entries) {
      final f = ConversationStateField.fromWire(e.key);
      if (f != null) out[f] = e.value;
    }
    return out;
  }

  Future<void> recordVersion(
    String conversationId,
    ConversationStateField f,
    FieldVersion version, {
    int? watermark,
  }) {
    (_versions[conversationId] ??= {})[f.wire] = version;
    if (watermark != null) {
      (_watermarks[conversationId] ??= {})[f.wire] = watermark;
    }
    return _persist();
  }

  Future<void> setBackground(
      String conversationId, ChatBackgroundOverride value) {
    if (value.isDefault) {
      _backgrounds.remove(conversationId);
    } else {
      _backgrounds[conversationId] = value;
    }
    return _persist();
  }

  Future<void> forget(String conversationId) {
    final had = _versions.remove(conversationId) != null;
    final hadW = _watermarks.remove(conversationId) != null;
    final hadB = _backgrounds.remove(conversationId) != null;
    if (!had && !hadW && !hadB) return Future<void>.value();
    return _persist();
  }

  Future<void> _persist() {
    _writeChain = _writeChain.then((_) async {
      try {
        await _storage.putString(_key, jsonEncode(_snapshot()));
      } catch (_) {/* best-effort; in-memory state stays authoritative */}
    });
    return _writeChain;
  }

  Map<String, Map<String, Object>> _snapshot() {
    final ids = {..._versions.keys, ..._watermarks.keys, ..._backgrounds.keys};
    return {
      for (final id in ids)
        id: <String, Object>{
          if (_versions[id] != null)
            'v': {
              for (final e in _versions[id]!.entries)
                e.key: [e.value.timestampMs, e.value.deviceId],
            },
          if (_watermarks[id] != null) 'w': _watermarks[id]!,
          if (_backgrounds[id] != null) 'bg': _backgrounds[id]!.toStorage(),
        },
    };
  }
}
