import 'dart:async';

import '../../../core/crypto/crypto_bridge.dart';
import '../../../core/crypto/sealed_envelope.dart';
import '../../../core/crypto/sealed_inner.dart';
import '../../../core/crypto/unidentified_access.dart';
import '../../../core/models/account.dart';
import '../../../core/models/api_error.dart';
import '../../../core/models/device.dart';
import '../../../core/models/envelope.dart' as wire;
import '../../../core/network/api_client.dart';
import '../../../core/push/sealed_delivered_receipt.dart';
import '../../../core/secure_storage/secure_storage.dart';
import '../../onboarding/session_repository.dart';
import '../models/conversation.dart';
import '../models/conversation_kind.dart';
import '../models/message_control.dart';

/// The SEND-side sealed-sender subsystem, lifted out of `ConversationsNotifier`
/// (which owns `_submit`, the universal send chokepoint). Responsibilities:
///   - Phase 1: wrap an outgoing payload in a per-recipient sealed layer when
///     the recipient device is cleared for it ([seal]).
///   - Phase 2 (unidentified access): deposit a sealed envelope on the
///     UNAUTHENTICATED path when we hold the recipient's UAK
///     ([trySubmitUnauthenticated]); share our own UAK with peers; publish our
///     UAK commitment on connect ([reportCommitmentIfNeeded]); store a peer's
///     shared UAK ([applyAccessKey]); mirror peer seal keys for the background
///     isolate ([mirrorPeerSealKeys]).
///
/// Heavy deps (crypto/api/sessions/secure-storage) are injected directly; the
/// few notifier-internal lookups (live conversation, device caches, the device
/// X25519 resolver, control send, and the live feature-flag reads) come in as
/// callbacks so this stays decoupled from the notifier's internals.
class SealedSender {
  SealedSender({
    required CryptoBridge crypto,
    required ApiClient api,
    required SessionRepository sessions,
    required SecureStorage secureStorage,
    required Conversation? Function(String conversationId) conversation,
    required List<AccountDevice> Function(String accountId) peerDevices,
    required List<Device> Function() myDevices,
    required Future<void> Function(Conversation convo) warmDeviceCaches,
    required List<int> Function(Conversation convo, String deviceId)
        x25519ForSender,
    required Future<void> Function(String conversationId, String body)
        sendControl,
    required bool Function() sealedEnabled,
    required bool Function() unauthEnabled,
  })  : _crypto = crypto,
        _api = api,
        _sessions = sessions,
        _secureStorage = secureStorage,
        _conversation = conversation,
        _peerDevices = peerDevices,
        _myDevices = myDevices,
        _warmDeviceCaches = warmDeviceCaches,
        _x25519ForSender = x25519ForSender,
        _sendControl = sendControl,
        _sealedEnabled = sealedEnabled,
        _unauthEnabled = unauthEnabled;

  final CryptoBridge _crypto;
  final ApiClient _api;
  final SessionRepository _sessions;
  final SecureStorage _secureStorage;
  final Conversation? Function(String) _conversation;
  final List<AccountDevice> Function(String) _peerDevices;
  final List<Device> Function() _myDevices;
  final Future<void> Function(Conversation) _warmDeviceCaches;
  final List<int> Function(Conversation, String) _x25519ForSender;
  final Future<void> Function(String, String) _sendControl;
  final bool Function() _sealedEnabled;
  final bool Function() _unauthEnabled;

  /// How long the unauth leg is skipped after it failed to REACH the server.
  /// Every call signal (offer, answer, each ICE batch) is its own sealed send,
  /// so without this a stalling network charged each of them the unauth
  /// connect budget before the authed fallback, stacking up call-setup delay.
  static const Duration unauthNetworkBackoff = Duration(seconds: 30);
  DateTime? _unauthSkipUntil;

  final SealedEnvelope _codec = SealedEnvelope();
  final Map<String, List<int>> _sealX25519Cache = {};
  final Set<String> _sealCapWarmed = {};
  final Map<String, List<int>> _peerUak = {};
  final Set<String> _uakSharedWith = {};
  List<int>? _cachedMyUak;
  bool _commitmentReported = false;

  /// Sealed-sender (Phase 1): wraps [payload] in a per-recipient sealed layer
  /// when the gate is on and the recipient device's X25519 key is resolvable.
  /// Returns the payload unchanged if disabled, already sealed, the key is
  /// unavailable, or sealing throws — sealing must NEVER block a send.
  Future<SubmitMessagePayload> seal(SubmitMessagePayload payload) async {
    if (!_sealedEnabled()) return payload;
    if (payload.envelopeType == wire.EnvelopeType.sealed) return payload;
    List<int>? x25519;
    try {
      x25519 = await _resolveRecipientX25519(
          payload.recipientAccountId,
          payload.recipientDeviceId,
          payload.conversationId);
    } catch (e) {
      // Resolving the recipient's sealing key failed unexpectedly. Deliver
      // unsealed rather than drop the message (privacy degrades, delivery does
      // not), but note it — this isn't the ordinary "peer lacks the capability"
      // path.
      // ignore: avoid_print
      print('sealed-sender: recipient key lookup failed '
          '(${payload.envelopeType}); sending unsealed: $e');
      return payload;
    }
    // No key ⇒ the recipient device hasn't advertised sealed-receive (e.g. an
    // older client). Expected; fall back to unsealed silently so we stay
    // interoperable. NOTE: once a device's key is cached (it ever supported
    // sealed) `_resolveRecipientX25519` keeps returning it, so a server can't
    // silently downgrade an already-sealed peer to unsealed.
    if (x25519 == null || x25519.length != 32) return payload;
    try {
      final session = await _sessions.current();
      final inner = SealedInner(
        conversationId: payload.conversationId,
        envelopeType: payload.envelopeType,
        senderDeviceId: session?.deviceId ?? '',
        ciphertext: payload.ciphertext,
      ).encode();
      final blob = await _codec.seal(
          recipientX25519PubKey: x25519, plaintext: inner);
      return SubmitMessagePayload(
        conversationId: '', // real conversation hidden inside the blob
        envelopeType: wire.EnvelopeType.sealed,
        recipientAccountId: payload.recipientAccountId,
        recipientDeviceId: payload.recipientDeviceId,
        ciphertext: blob,
        ttlSeconds: payload.ttlSeconds,
        pushKind: payload.pushKind, // call-ring hint must survive sealing
      );
    } catch (e) {
      // We HAD a recipient key but sealing itself threw — an anomaly, not a
      // capability gap. Warn loudly; still deliver unsealed so a message is
      // never dropped. This path should be rare and investigated.
      // ignore: avoid_print
      print('sealed-sender: WARNING seal failed despite a resolved key '
          '(${payload.envelopeType}); sending unsealed: $e');
      return payload;
    }
  }

  /// Sealed-sender Phase 2 (unidentified access): try to deposit a sealed
  /// [payload] on the UNAUTHENTICATED path (no JWT → the server never sees the
  /// sender) when we hold the recipient's UAK; also ensure the peer has OUR UAK
  /// so they can reciprocate. Returns the result on success, or null to fall
  /// through to the authenticated send (recipient hasn't enabled it, wrong/stale
  /// key, rate limited, network) — privacy degrades, delivery does not.
  Future<SubmitMessageResult?> trySubmitUnauthenticated(
      SubmitMessagePayload payload) async {
    if (!_unauthEnabled() ||
        payload.envelopeType != wire.EnvelopeType.sealed) {
      return null;
    }
    unawaited(_maybeShareMyUak(payload.recipientAccountId));
    final uak = await _uakForRecipient(payload.recipientAccountId);
    final skipUntil = _unauthSkipUntil;
    if (skipUntil != null && DateTime.now().isBefore(skipUntil)) return null;
    if (uak != null && uak.isNotEmpty) {
      try {
        return await _api.submitSealedUnauthenticated(payload, uak);
      } catch (e) {
        // ignore: avoid_print
        print('unidentified-access: unauth send failed; authed fallback: $e');
        // No HTTP status = the request never got an answer (connect timeout,
        // no route). A 403/429 is a per-recipient verdict and doesn't back off.
        if (e is ApiError && e.statusCode == null) {
          _unauthSkipUntil = DateTime.now().add(unauthNetworkBackoff);
        }
      }
    }
    return null;
  }

  /// Publishes our UAK commitment so contacts can send us sealed messages on the
  /// unauthenticated path. Best-effort + once per session; gated by the flag. A
  /// failure allows a retry next connect.
  void reportCommitmentIfNeeded() {
    if (!_unauthEnabled() || _commitmentReported) return;
    _commitmentReported = true;
    unawaited(Future<void>(() async {
      if (_crypto is! UnidentifiedAccessProvider) return;
      final commitment = await (_crypto as UnidentifiedAccessProvider)
          .unidentifiedAccessCommitment();
      await _api.reportAccessKeyCommitment(commitment);
    }).catchError((_) {
      _commitmentReported = false;
    }));
  }

  /// Stores a peer's shared UAK (from an inbound access-key control), keyed by
  /// the peer's account, so we can later deposit sealed messages to them on the
  /// unauthenticated path. Accept ONLY for a 1:1 (caller already verified it came
  /// from the peer, not one of our own devices).
  void applyAccessKey(Conversation convo, List<int> accessKey) {
    if (convo.kind != ConversationKind.oneToOne) return;
    if (convo.peerAccountId.isNotEmpty) {
      _peerUak[convo.peerAccountId] = accessKey;
    }
  }

  /// Mirrors a 1:1 peer DEVICE's sealing keys into SecureStorage so the FCM
  /// background isolate can send it a sealed "delivered" receipt for a message
  /// that arrives while the app is closed. Stores only the device's x25519 PUB
  /// and the peer account's UAK (a shared, rotatable, low-value secret) — never
  /// a private key. No-op for groups, before the peer's UAK is shared, or when
  /// the device's x25519 isn't resolvable. Best-effort.
  Future<void> mirrorPeerSealKeys(
      String senderDeviceId, String conversationId) async {
    if (senderDeviceId.isEmpty) return;
    final convo = _conversation(conversationId);
    if (convo == null || convo.kind != ConversationKind.oneToOne) return;
    final uak = _peerUak[convo.peerAccountId];
    if (uak == null || uak.isEmpty) return;
    final x25519 = await _resolveRecipientX25519(
        convo.peerAccountId, senderDeviceId, conversationId);
    if (x25519 == null || x25519.length != 32) return;
    try {
      await writePeerSealKeys(_secureStorage, senderDeviceId,
          x25519Pub: x25519, uak: uak);
    } catch (_) {/* best-effort mirror; never affects the receive path */}
  }

  /// Clears all sealed/UAK state on sign-out / local-state wipe.
  void clear() {
    _sealX25519Cache.clear();
    _sealCapWarmed.clear();
    _peerUak.clear();
    _uakSharedWith.clear();
    _cachedMyUak = null;
    _commitmentReported = false;
  }

  // ── internals ───────────────────────────────────────────────────────────────

  /// Resolves a recipient DEVICE's X25519 pub for sealing, or null when unknown
  /// or not cleared to seal (caller falls back to unsealed). Group members carry
  /// per-device x25519 directly (not capability-gated); 1:1 peer + own devices
  /// are capability-gated (only seal to a device that advertised sealed-receive,
  /// warming the caches once per device on a miss).
  Future<List<int>?> _resolveRecipientX25519(
      String accountId, String deviceId, String conversationId) async {
    final cached = _sealX25519Cache[deviceId];
    if (cached != null) return cached;
    final convo = _conversation(conversationId);
    if (convo == null) return null;

    for (final m in convo.members) {
      if (m.deviceId == deviceId && m.x25519PubKey.length == 32) {
        _sealX25519Cache[deviceId] = m.x25519PubKey;
        return m.x25519PubKey;
      }
    }

    if (!_deviceSupportsSealed(convo, deviceId) &&
        _sealCapWarmed.add(deviceId)) {
      await _warmDeviceCaches(convo);
    }
    if (!_deviceSupportsSealed(convo, deviceId)) return null; // unsealed
    final x = _x25519ForSender(convo, deviceId);
    if (x.length == 32) {
      _sealX25519Cache[deviceId] = x;
      return x;
    }
    return null;
  }

  /// Whether [deviceId] (a 1:1 peer device or one of our own) has advertised it
  /// can OPEN sealed-sender envelopes, from the live device caches. Unknown
  /// devices read as false (conservative — send unsealed).
  bool _deviceSupportsSealed(Conversation convo, String deviceId) {
    for (final d in _peerDevices(convo.peerAccountId)) {
      if (d.deviceId == deviceId) return d.supportsSealed;
    }
    for (final d in _myDevices()) {
      if (d.deviceId == deviceId) return d.supportsSealed;
    }
    return false;
  }

  /// This account's own UAK, derived + cached. Null when the crypto bridge
  /// doesn't expose it (test fakes).
  Future<List<int>?> _myUak() async {
    final cached = _cachedMyUak;
    if (cached != null) return cached;
    if (_crypto is! UnidentifiedAccessProvider) return null;
    try {
      final uak =
          await (_crypto as UnidentifiedAccessProvider).unidentifiedAccessKey();
      _cachedMyUak = uak;
      return uak;
    } catch (_) {
      return null;
    }
  }

  /// The UAK to present when depositing a sealed envelope to [accountId]: our
  /// OWN UAK for a self-sync recipient, else the peer's UAK if they've shared it.
  Future<List<int>?> _uakForRecipient(String accountId) async {
    final session = await _sessions.current();
    if (session != null && accountId == session.accountId) {
      return _myUak();
    }
    return _peerUak[accountId];
  }

  /// Shares OUR UAK with a peer (once per session) over the E2EE channel, so the
  /// peer can deposit sealed messages to us on the unauthenticated path.
  Future<void> _maybeShareMyUak(String accountId) async {
    if (!_unauthEnabled()) return;
    if (accountId.isEmpty || _uakSharedWith.contains(accountId)) return;
    final session = await _sessions.current();
    if (session == null || accountId == session.accountId) return; // not to self
    final convoId = Conversation.oneToOneId(session.accountId, accountId);
    if (_conversation(convoId) == null) return; // no 1:1 thread to carry it
    final uak = await _myUak();
    if (uak == null || uak.isEmpty) return;
    _uakSharedWith.add(accountId); // mark BEFORE sending — prevents re-entrancy
    try {
      await _sendControl(convoId, MessageControl.accessKey(uak).encode());
    } catch (_) {
      _uakSharedWith.remove(accountId); // let a later send retry the share
    }
  }
}
