import 'dart:convert';

import '../../../core/secure_storage/secure_storage.dart';

/// A small persisted set of string markers (e.g. "deviceId|conversationId")
/// kept as a JSON list under one secure-storage key. Best-effort: a read
/// failure yields an empty set and a write failure is swallowed.
class PersistedMarkerSet {
  PersistedMarkerSet({required SecureStorage storage, required String key})
      : _storage = storage,
        _key = key;

  final SecureStorage _storage;
  final String _key;

  Future<Set<String>> load() async {
    try {
      final raw = await _storage.getString(_key);
      if (raw == null) return <String>{};
      return (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> save(Set<String> markers) async {
    try {
      await _storage.putString(_key, jsonEncode(markers.toList()));
    } catch (_) {/* best-effort */}
  }
}
