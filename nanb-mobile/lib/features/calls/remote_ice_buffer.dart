/// Inbound trickle-ICE for one call: buffers the peer's candidates until the
/// remote description they belong to has been applied.
///
/// Inbound signals are dispatched concurrently (each `handleSignal` is fired
/// unawaited), and the media engine may still be starting when the first ones
/// arrive. A candidate handed to the peer connection before its remote
/// description exists is rejected and lost — so candidates that arrive while the
/// offer/answer is still being applied (or before it arrives at all) wait here
/// and are applied, in order, by [release].
class RemoteIceBuffer {
  RemoteIceBuffer({
    required Future<void> Function(Map<String, dynamic> candidate) apply,
  }) : _apply = apply;

  final Future<void> Function(Map<String, dynamic> candidate) _apply;
  final List<Map<String, dynamic>> _pending = [];
  bool _ready = false;

  /// Applies [candidate] now if the remote description is in place, else
  /// buffers it for [release].
  Future<void> add(Map<String, dynamic> candidate) async {
    if (!_ready) {
      _pending.add(candidate);
      return;
    }
    await _applySafely(candidate);
  }

  /// Marks the remote description as NOT applied (a new offer/answer is about
  /// to be set); candidates buffer until the next [release].
  void hold() => _ready = false;

  /// The remote description is applied: flush the buffer, oldest first.
  Future<void> release() async {
    _ready = true;
    while (_ready && _pending.isNotEmpty) {
      await _applySafely(_pending.removeAt(0));
    }
  }

  /// Drops everything buffered and resets to not-ready (call end / new call).
  void clear() {
    _pending.clear();
    _ready = false;
  }

  /// A candidate from a superseded ICE generation (ufrag no longer current) is
  /// legitimately rejected by the peer connection; that must never take the
  /// call down, so failures are absorbed.
  Future<void> _applySafely(Map<String, dynamic> candidate) async {
    try {
      await _apply(candidate);
    } catch (_) {/* stale / rejected candidate — ignore */}
  }
}
