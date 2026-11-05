import 'tor_status.dart';

/// Seam over the native embedded-Tor engine (Guardian Project C-tor, bound via
/// the `nanb_crypto` plugin). Production wiring is [TorEngineChannel]; tests
/// inject a fake. Keeping [TorController] behind this seam makes the lifecycle
/// logic fully unit-testable without the native side.
abstract class TorEngine {
  /// Status/bootstrap updates. A successful run progresses
  /// starting → bootstrapping → [TorPhase.connected] (carrying a `socksPort`);
  /// a failure emits [TorPhase.error].
  Stream<TorStatus> get status;

  /// Start the engine and begin bootstrapping. Progress arrives on [status];
  /// this future completing only means the start request was accepted, not that
  /// Tor is connected.
  Future<void> start();

  /// Stop the engine and release the SOCKS port.
  Future<void> stop();

  /// Re-establish a connection an OS suspend/resume may have torn down. On iOS
  /// the app is suspended in the background, which kills Tor's circuits (and the
  /// SOCKS path) while the engine still reports `connected`; the production
  /// channel overrides this to reset Tor's network in place and re-emit status.
  /// Defaults to a plain [start] so test fakes / non-iOS need no change.
  Future<void> reconnect() => start();

  /// Hint that the app is about to be backgrounded (called while Tor is still
  /// connected). The production channel puts Arti into a **dormant** state so the
  /// impending OS suspend freezes an idle engine while keeping the client + its
  /// SOCKS port warm — so [wake] can resume it in place instead of paying a full
  /// re-bootstrap. Defaults to a no-op so test fakes need no change.
  Future<void> prepareForBackground() async {}

  /// Resume from the dormant state entered by [prepareForBackground], called on
  /// app foreground. Cheap: the client + SOCKS port survived, so this just
  /// resumes background circuit upkeep (Arti also auto-wakes on first use). The
  /// opposite of a full [reconnect]. Defaults to a no-op for test fakes.
  Future<void> wake() async {}
}
