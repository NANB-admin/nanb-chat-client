import '../chat/conversations_notifier.dart';
import '../chat/models/conversation.dart';
import '../onboarding/session_repository.dart';
import 'call_transport.dart';
import 'models/call_signal.dart';

/// [CallTransport] backed by [ConversationsNotifier]: every signal is encrypted
/// and submitted over the existing 1:1 E2EE control-message path
/// ([ConversationsNotifier.sendCallSignal]).
///
/// Addressing: the invite and "all devices" signals ring EVERY current device
/// of the peer account, and a directed signal goes to the one device in the
/// call. These used to target the conversation row's single `peerDeviceId`,
/// which goes stale when the peer reinstalls — messages (fanned out to the
/// directory) still arrived, but the invite rang a dead device and the call
/// hung on "Calling…" (reproduced on-device 2026-10-21). The [CallController]
/// already implements the first-accept-wins logic the fan-out needs.
class NotifierCallTransport implements CallTransport {
  NotifierCallTransport({
    required ConversationsNotifier Function() notifier,
    required SessionRepository sessions,
  })  : _notifier = notifier,
        _sessions = sessions;

  /// Resolves the CURRENT notifier on each send rather than capturing one
  /// instance: a transport change (e.g. a built-in-Tor restart) rebuilds
  /// `conversationsProvider`, so a captured instance would send over a dead,
  /// disposed notifier and the signal would never leave.
  final ConversationsNotifier Function() _notifier;
  final SessionRepository _sessions;

  /// The deterministic 1:1 conversation id between us and [toAccountId].
  Future<String?> _conversationId(String toAccountId) async {
    final session = await _sessions.current();
    if (session == null) return null;
    return Conversation.oneToOneId(session.accountId, toAccountId);
  }

  Future<void> _send(String toAccountId, CallSignal signal,
      {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) async {
    final conversationId = await _conversationId(toAccountId);
    if (conversationId == null) return;
    await _notifier().sendCallSignal(conversationId, signal,
        pushKind: pushKind,
        toDeviceId: toDeviceId,
        allPeerDevices: allPeerDevices);
  }

  @override
  Future<void> sendInvite({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      // The ring rides a 'call' push so a closed/locked device rings.
      _send(toAccountId, signal, pushKind: 'call', allPeerDevices: true);

  @override
  Future<void> sendToDevice({
    required String toAccountId,
    required String toDeviceId,
    required CallSignal signal,
  }) =>
      _send(toAccountId, signal, toDeviceId: toDeviceId);

  @override
  Future<void> sendToAllDevices({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      _send(toAccountId, signal, allPeerDevices: true);

  @override
  Future<void> sendToOwnDevices({
    required String peerAccountId,
    required CallSignal signal,
  }) async {
    final conversationId = await _conversationId(peerAccountId);
    if (conversationId == null) return;
    await _notifier().sendSelfControl(conversationId, signal.encode());
  }
}
