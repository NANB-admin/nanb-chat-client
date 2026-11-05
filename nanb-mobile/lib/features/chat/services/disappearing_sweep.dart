import 'dart:async';

import '../models/chat_message.dart';
import 'media_cache.dart';
import 'notifier_service_host.dart';
import 'temp_media_store.dart';

/// Removes expired messages from both the persisted DB and in-memory state.
///
/// A message disappears at the SHORTER of two timers ("shorter-of-the-two wins"):
///   (a) the sender's stamped [ChatMessage.expiresAt] (the `_ttl` wire header), and
///   (b) `sentTs + this device's effective TTL` — the per-conversation override
///       (`Conversation.disappearingTtl`, seconds) else the global default.
/// So the sender can still make a message self-destruct fast on the other end,
/// AND each device's own retention setting applies to its copies — immediately
/// and RETROACTIVELY (changing the setting re-evaluates existing messages, since
/// the local timer is computed from the CURRENT setting, not stamped at send).
/// Driven by a periodic timer + the foreground-resume hook + the chat-list pull.
/// Extracted from `ConversationsNotifier`.
class DisappearingSweep {
  DisappearingSweep({
    required NotifierServiceHost host,
    required MediaCache mediaCache,
    required TempMediaStore tempMediaStore,
    required Duration? Function() ttlProvider,
  })  : _host = host,
        _mediaCache = mediaCache,
        _tempMediaStore = tempMediaStore,
        _ttlProvider = ttlProvider;

  final NotifierServiceHost _host;
  final MediaCache _mediaCache;
  final TempMediaStore _tempMediaStore;
  final Duration? Function() _ttlProvider;

  /// Sweeps using the current global default TTL (from the injected provider);
  /// per-conversation overrides are read off each conversation.
  Future<void> runNow() => run(_ttlProvider());

  /// Removes expired messages: at the SHORTER of the sender's stamped expiry and
  /// `sentTs + effective TTL` (per-conversation override else [globalTtl]). See
  /// the class doc. A conversation with no override and a null [globalTtl] keeps
  /// only the sender-stamped expiry.
  Future<void> run(Duration? globalTtl) async {
    final now = DateTime.now().toUtc();
    // Persisted DB: sender-stamped expiry + this device's local retention.
    await _host.db.deleteExpiredMessages(now);
    await _host.db.deleteMessagesPastLocalRetention(now, globalTtl?.inSeconds);
    var changed = false;
    for (final convo in _host.allConversations().toList()) {
      final effective = convo.disappearingTtl > 0
          ? Duration(seconds: convo.disappearingTtl)
          : globalTtl;
      final keep = <ChatMessage>[];
      for (final m in convo.messages) {
        if (_isExpired(m, now, effective)) {
          // Drop this message's media bytes + thumbnail from the cache too,
          // and reclaim any decrypted temp copy on disk (opened attachment /
          // video the user viewed) so an expired message leaves no plaintext.
          _mediaCache.evict(m.envelopeId);
          _mediaCache.evictThumbnail(m.envelopeId);
          await _tempMediaStore.deleteForEnvelope(m.envelopeId);
        } else {
          keep.add(m);
        }
      }
      if (keep.length != convo.messages.length) {
        _host.setConversation(convo.id, convo.copyWith(messages: keep));
        changed = true;
      }
    }
    if (changed) _host.notifyHost();
  }

  /// Expired once [now] is at/after the SHORTER of the sender's stamped expiry
  /// (if any) and `sentTs + effectiveTtl`. A null [effectiveTtl] (no override and
  /// no global) means only the stamped expiry applies.
  bool _isExpired(ChatMessage m, DateTime now, Duration? effectiveTtl) {
    DateTime? expiry = m.expiresAt;
    if (effectiveTtl != null) {
      final localExpiry = m.serverTs.add(effectiveTtl);
      if (expiry == null || localExpiry.isBefore(expiry)) expiry = localExpiry;
    }
    return expiry != null && !now.isBefore(expiry);
  }
}
