import 'models/call_signal.dart';

/// How the [CallController] puts signaling on the wire. The production
/// implementation (a later increment) maps these onto the existing E2EE paths:
/// `sendInvite` rides the stored delivery path (MLS control payload + push, so
/// offline/locked devices wake to ring), while the fast frames ride the
/// WebSocket *ephemeral* channel — both MLS-encrypted so the server only relays
/// ciphertext. Injecting it keeps the state machine decoupled and testable.
abstract class CallTransport {
  /// The "ring": deliver [signal] (a [CallSignalType.invite]) to **every**
  /// device of [toAccountId] via the stored + push path.
  Future<void> sendInvite({
    required String toAccountId,
    required CallSignal signal,
  });

  /// Send a fast [signal] to **one** device over the ephemeral channel.
  Future<void> sendToDevice({
    required String toAccountId,
    required String toDeviceId,
    required CallSignal signal,
  });

  /// Send a fast [signal] to **every** device of [toAccountId] over the
  /// ephemeral channel — used to cancel the ring on the non-answering devices.
  Future<void> sendToAllDevices({
    required String toAccountId,
    required CallSignal signal,
  });

  /// Send a fast [signal] to **this account's own other devices** only (never
  /// the peer) — used to stop the ring on the siblings the moment this device
  /// answers or declines. [peerAccountId] names the 1:1 the call belongs to.
  Future<void> sendToOwnDevices({
    required String peerAccountId,
    required CallSignal signal,
  });
}
