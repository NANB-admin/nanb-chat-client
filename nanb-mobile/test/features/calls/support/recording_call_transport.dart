import 'dart:async';

import 'package:nanb_chat/features/calls/call_transport.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';

/// A [CallTransport] fake that records every signal in send order, and can make
/// sends of chosen types fail ([failTypes]) or stall until a gate completes
/// ([gates]) — the real transport's failure and slow modes.
class RecordingCallTransport implements CallTransport {
  /// Every send attempt, in order: (method, target device, signal).
  final List<(String, String?, CallSignal)> sent = [];

  final Set<CallSignalType> failTypes = {};
  final Map<CallSignalType, Completer<void>> gates = {};

  Future<void> _record(String method, String? device, CallSignal signal) async {
    sent.add((method, device, signal));
    if (failTypes.contains(signal.type)) throw StateError('transport down');
    final gate = gates[signal.type];
    if (gate != null) await gate.future;
  }

  @override
  Future<void> sendInvite({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      _record('invite', null, signal);

  @override
  Future<void> sendToDevice({
    required String toAccountId,
    required String toDeviceId,
    required CallSignal signal,
  }) =>
      _record('device', toDeviceId, signal);

  @override
  Future<void> sendToAllDevices({
    required String toAccountId,
    required CallSignal signal,
  }) =>
      _record('all', null, signal);

  @override
  Future<void> sendToOwnDevices({
    required String peerAccountId,
    required CallSignal signal,
  }) =>
      _record('own', null, signal);

  /// The signals of [type], in send order.
  List<CallSignal> ofType(CallSignalType type) =>
      [for (final s in sent) if (s.$3.type == type) s.$3];

  /// The send-order position of the first signal of [type], or -1.
  int firstIndexOf(CallSignalType type) =>
      sent.indexWhere((s) => s.$3.type == type);
}
