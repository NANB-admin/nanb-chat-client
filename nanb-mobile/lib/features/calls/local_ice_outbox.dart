import 'dart:async';

/// Outbound trickle-ICE for one call: holds local candidates until the SDP they
/// belong to is on the wire, then ships them — coalesced.
///
/// Two defects this exists to remove:
///
///  1. **Candidates overtaking their SDP.** WebRTC starts gathering the moment
///     `setLocalDescription` runs, i.e. INSIDE `createOffer`/`createAnswer` and
///     before the controller has even handed the offer/answer to the transport.
///     Sending each candidate straight away put it on the conversation's FIFO
///     lock AHEAD of its SDP, so it reached the peer first, where
///     `addIceCandidate` without a remote description fails and the candidate is
///     lost. A relay-only call has only a couple of candidates; losing them
///     leaves ICE with nothing to check — the call sits in "Connecting…" until the
///     connect timeout. Hence the gate: [hold] before producing an SDP, [release]
///     once it has been sent.
///  2. **One E2EE submit per candidate.** Every signal is a full encrypt +
///     submit serialised on the per-conversation lock, so N candidates cost N
///     round trips back to back. While one batch is in flight the rest
///     accumulate and leave together as the next batch.
///
/// A failed send is swallowed: the controller's connect-retry watchdog re-offers
/// with fresh ICE, which is the recovery for lost candidates.
class LocalIceOutbox {
  LocalIceOutbox({
    required Future<void> Function(List<Map<String, dynamic>> batch) send,
  }) : _send = send;

  final Future<void> Function(List<Map<String, dynamic>> batch) _send;
  final List<Map<String, dynamic>> _queue = [];
  bool _open = false;
  bool _draining = false;

  /// Bumped by [clear] so a drain loop from a previous call stops shipping.
  int _generation = 0;

  /// Queues [candidate]; ships it now if the gate is open.
  void add(Map<String, dynamic> candidate) {
    _queue.add(candidate);
    _drain();
  }

  /// Closes the gate: candidates queue until [release]. Call BEFORE producing
  /// the SDP the next candidates will belong to.
  void hold() => _open = false;

  /// Opens the gate and ships everything queued. Call once the SDP is sent.
  void release() {
    _open = true;
    _drain();
  }

  /// Drops everything queued and closes the gate (call end / new call).
  void clear() {
    _generation++;
    _queue.clear();
    _open = false;
  }

  void _drain() {
    if (!_open || _draining || _queue.isEmpty) return;
    _draining = true;
    final generation = _generation;
    unawaited(() async {
      try {
        while (_open && _queue.isNotEmpty && generation == _generation) {
          final batch = List<Map<String, dynamic>>.of(_queue);
          _queue.clear();
          try {
            await _send(batch);
          } catch (_) {/* best-effort — see class doc */}
        }
      } finally {
        if (generation == _generation) {
          _draining = false;
          // Anything that arrived after the loop's last check.
          _drain();
        } else {
          _draining = false;
        }
      }
    }());
  }
}
