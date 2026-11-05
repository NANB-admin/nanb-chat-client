import 'dart:convert';

import '../../core/secure_storage/secure_storage.dart';
import '../chat/conversations_notifier.dart';

/// Names the caller on an incoming ring that arrived by push.
///
/// On a cold launch — PushKit starting a killed app, the whole reason CallKit
/// exists — the conversation store isn't hydrated yet, so the live lookup comes
/// back empty and the ring said "Chat" instead of who is calling (seen on-device
/// 2026-10-21). The foreground keeps a conversationId -> name mirror in
/// SecureStorage for exactly this (the Android background isolate reads it), and
/// that needs no database, so it is the fallback.
class CallerNameResolver {
  CallerNameResolver({
    required String? Function(String conversationId) liveName,
    required SecureStorage storage,
  })  : _liveName = liveName,
        _storage = storage;

  final String? Function(String conversationId) _liveName;
  final SecureStorage _storage;

  /// The caller's name, or '' when neither source knows it.
  Future<String> resolve(String conversationId) async {
    final live = _liveName(conversationId);
    if (live != null && live.isNotEmpty) return live;
    try {
      final raw =
          await _storage.getString(ConversationsNotifier.callPeerNamesKey);
      if (raw == null || raw.isEmpty) return '';
      final names = (jsonDecode(raw) as Map).cast<String, String>();
      return names[conversationId] ?? '';
    } catch (_) {
      return ''; // unreadable mirror — the ring still shows the app name
    }
  }
}
