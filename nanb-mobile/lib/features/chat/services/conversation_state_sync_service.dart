import 'dart:async';

import '../models/chat_background_override.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_state_field.dart';
import '../models/conversation_state_update.dart';
import '../models/field_version.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import '../models/state_field_change.dart';
import 'conversation_settings_service.dart';
import 'conversation_state_store.dart';
import 'notifier_service_host.dart';

/// User-facing side of per-chat state sync. Every wrapper makes the change
/// locally through [ConversationSettingsService] (unchanged behaviour), stamps
/// the field with a fresh LWW version, and tells the account's OTHER devices
/// with a sparse `conversation_state` control (`sendSelfControl`, best-effort,
/// detached). The inbound side is [ConversationStateApplier], which never calls
/// back into these wrappers, so a sync cannot echo.
class ConversationStateSyncService {
  ConversationStateSyncService(
    this._host, {
    required ConversationSettingsService settings,
    required ConversationStateStore store,
    DateTime Function()? now,
    Duration readDebounce = const Duration(seconds: 5),
  })  : _settings = settings,
        _store = store,
        _now = now ?? DateTime.now,
        _readDebounce = readDebounce;

  final NotifierServiceHost _host;
  final ConversationSettingsService _settings;
  final ConversationStateStore _store;
  final DateTime Function() _now;
  final Duration _readDebounce;
  final Map<String, Timer> _readTimers = {};

  Future<void> load() => _store.load();

  ChatBackgroundOverride backgroundOverrideOf(String conversationId) =>
      _store.backgroundOf(conversationId);

  Future<void> forget(String conversationId) {
    _readTimers.remove(conversationId)?.cancel();
    return _store.forget(conversationId);
  }

  void dispose() {
    for (final t in _readTimers.values) {
      t.cancel();
    }
    _readTimers.clear();
  }

  // ---- user-facing setters -------------------------------------------------

  Future<void> setMuted(String id, bool value) => _flag(
      id, ConversationStateField.muted, value, (c) => c.muted,
      _settings.setMuted);

  Future<void> setPinned(String id, bool value) => _flag(
      id, ConversationStateField.pinned, value, (c) => c.pinned,
      _settings.setPinned);

  Future<void> setArchived(String id, bool value) => _flag(
      id, ConversationStateField.archived, value, (c) => c.archived,
      _settings.setArchived);

  Future<void> setBlocked(String id, bool value) => _flag(
      id, ConversationStateField.blocked, value, (c) => c.blocked,
      _settings.setBlocked);

  Future<void> setVerified(String id, bool value) => _flag(
      id, ConversationStateField.verified, value, (c) => c.verified,
      _settings.setVerified);

  Future<void> setDisappearingTtl(String id, int ttlSeconds) async {
    final convo = _host.conversation(id);
    if (convo == null) return;
    final normalized = ttlSeconds > 0 ? ttlSeconds : -1;
    if (convo.disappearingTtl == normalized) return;
    await _settings.setDisappearingTtl(id, ttlSeconds);
    await _commit(id, ConversationStateField.disappearingTtl,
        (v) => StateFieldChange.number(normalized, v));
  }

  /// Sets the per-chat background override. A device-local photo is stored but
  /// never synced; a preset / 'default' is.
  Future<void> setBackgroundOverride(
      String id, ChatBackgroundOverride value) async {
    if (_host.conversation(id) == null) return;
    await _store.load();
    if (_store.backgroundOf(id) == value) return;
    await _store.setBackground(id, value);
    _host.notifyHost();
    final wire = value.syncWire;
    if (wire == null) return;
    await _commit(id, ConversationStateField.background,
        (v) => StateFieldChange.text(wire, v));
  }

  Future<void> _flag(
    String id,
    ConversationStateField field,
    bool value,
    bool Function(Conversation) current,
    Future<void> Function(String, bool) apply,
  ) async {
    final convo = _host.conversation(id);
    if (convo == null || current(convo) == value) return;
    await apply(id, value);
    await _commit(id, field, (v) => StateFieldChange.flag(value, v));
  }

  // ---- read position & clear history ---------------------------------------

  /// Called whenever the user is looking at [id] (it runs from `markRead`).
  /// When the newest incoming message the user has seen advanced past the stored
  /// read position, records it and (debounced, at most one send per window per
  /// conversation) tells the other devices.
  Future<void> noteRead(String id) async {
    final convo = _host.conversation(id);
    if (convo == null) return;
    final newest = _newestIncomingMs(convo);
    if (newest == null) return;
    if (!_store.isLoaded) await _store.load();
    if (newest <= _store.watermarkOf(id, ConversationStateField.readUpToMs)) {
      return;
    }
    final version = await _nextVersion(id, ConversationStateField.readUpToMs);
    if (version == null) return;
    await _store.recordVersion(id, ConversationStateField.readUpToMs, version,
        watermark: newest);
    if (_readTimers.containsKey(id)) return; // a send is already scheduled
    _readTimers[id] = Timer(_readDebounce, () {
      _readTimers.remove(id);
      _sendWatermark(id, ConversationStateField.readUpToMs);
    });
  }

  /// Records that history up to [upToMs] was cleared here and tells the others.
  Future<void> noteCleared(String id, int upToMs) async {
    if (upToMs <= 0) return;
    await _store.load();
    if (upToMs <= _store.watermarkOf(id, ConversationStateField.clearedAtMs)) {
      return;
    }
    final version = await _nextVersion(id, ConversationStateField.clearedAtMs);
    if (version == null) return;
    await _store.recordVersion(id, ConversationStateField.clearedAtMs, version,
        watermark: upToMs);
    _sendWatermark(id, ConversationStateField.clearedAtMs);
  }

  /// serverTs (ms) of the newest message in [convo], for the clear watermark.
  int? newestMessageMs(Conversation convo) {
    int? newest;
    for (final m in convo.messages) {
      final ms = m.serverTs.millisecondsSinceEpoch;
      if (newest == null || ms > newest) newest = ms;
    }
    return newest;
  }

  int? _newestIncomingMs(Conversation convo) {
    int? newest;
    for (final ChatMessage m in convo.messages) {
      if (m.mine || m.kind == MessageKind.system) continue;
      final ms = m.serverTs.millisecondsSinceEpoch;
      if (newest == null || ms > newest) newest = ms;
    }
    return newest;
  }

  void _sendWatermark(String id, ConversationStateField field) {
    final version = _store.versionOf(id, field);
    if (version == null) return;
    final value = _store.watermarkOf(id, field);
    _send(id, ConversationStateUpdate(
        {field: StateFieldChange.number(value, version)}));
  }

  // ---- bootstrap -----------------------------------------------------------

  /// Sends [id]'s FULL current state (only fields that differ from defaults,
  /// each with its stored version) to our other devices so a freshly linked one
  /// inherits it. Throws on a send failure so the caller can decide; callers
  /// treat it as best-effort.
  Future<void> sendFullState(String id) async {
    final convo = _host.conversation(id);
    if (convo == null) return;
    await _store.load();
    final self = await _selfDevice();
    if (self == null) return;
    FieldVersion versionOf(ConversationStateField f) =>
        _store.versionOf(id, f) ?? FieldVersion(0, self);
    final changes = <ConversationStateField, StateFieldChange>{};
    void flag(ConversationStateField f, bool on) {
      if (on) changes[f] = StateFieldChange.flag(true, versionOf(f));
    }

    flag(ConversationStateField.muted, convo.muted);
    flag(ConversationStateField.pinned, convo.pinned);
    flag(ConversationStateField.archived, convo.archived);
    flag(ConversationStateField.blocked, convo.blocked);
    flag(ConversationStateField.verified, convo.verified);
    if (convo.disappearingTtl > 0) {
      changes[ConversationStateField.disappearingTtl] = StateFieldChange.number(
          convo.disappearingTtl,
          versionOf(ConversationStateField.disappearingTtl));
    }
    final wire = _store.backgroundOf(id).syncWire;
    if (wire != null && wire != ChatBackgroundOverride.defaultWire) {
      changes[ConversationStateField.background] = StateFieldChange.text(
          wire, versionOf(ConversationStateField.background));
    }
    for (final f in const [
      ConversationStateField.readUpToMs,
      ConversationStateField.clearedAtMs,
    ]) {
      final w = _store.watermarkOf(id, f);
      if (w > 0) changes[f] = StateFieldChange.number(w, versionOf(f));
    }
    if (changes.isEmpty) return;
    await _host.sendSelfControl(id,
        MessageControl.conversationState(ConversationStateUpdate(changes)).encode());
  }

  // ---- plumbing ------------------------------------------------------------

  Future<String?> _selfDevice() async {
    try {
      return await _host.selfDeviceId();
    } catch (_) {
      return null; // no session
    }
  }

  /// A version strictly greater than whatever we hold, so a local edit made
  /// after applying a sibling's newer write still wins locally.
  Future<FieldVersion?> _nextVersion(
      String id, ConversationStateField field) async {
    final dev = await _selfDevice();
    if (dev == null) return null;
    final prev = _store.versionOf(id, field);
    var ts = _now().millisecondsSinceEpoch;
    if (prev != null && ts <= prev.timestampMs) ts = prev.timestampMs + 1;
    return FieldVersion(ts, dev);
  }

  Future<void> _commit(String id, ConversationStateField field,
      StateFieldChange Function(FieldVersion) build) async {
    await _store.load();
    final version = await _nextVersion(id, field);
    if (version == null) return;
    await _store.recordVersion(id, field, version);
    _send(id, ConversationStateUpdate({field: build(version)}));
  }

  void _send(String id, ConversationStateUpdate update) {
    unawaited(_host
        .sendSelfControl(
            id, MessageControl.conversationState(update).encode())
        .catchError((_) {/* best-effort; the local change already happened */}));
  }
}
