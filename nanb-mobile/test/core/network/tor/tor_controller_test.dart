import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/tor/tor_controller.dart';
import 'package:nanb_chat/core/network/tor/tor_engine.dart';
import 'package:nanb_chat/core/network/tor/tor_status.dart';

class _FakeEngine implements TorEngine {
  final _ctrl = StreamController<TorStatus>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int reconnectCalls = 0;
  int prepareForBackgroundCalls = 0;
  int wakeCalls = 0;
  bool throwOnStart = false;
  bool throwOnReconnect = false;
  bool throwOnWake = false;

  @override
  Stream<TorStatus> get status => _ctrl.stream;

  @override
  Future<void> start() async {
    startCalls++;
    if (throwOnStart) throw StateError('boom');
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> reconnect() async {
    reconnectCalls++;
    if (throwOnReconnect) throw StateError('reboom');
  }

  @override
  Future<void> prepareForBackground() async => prepareForBackgroundCalls++;

  @override
  Future<void> wake() async {
    wakeCalls++;
    if (throwOnWake) throw StateError('wakeboom');
  }

  void emit(TorStatus s) => _ctrl.add(s);
  Future<void> close() => _ctrl.close();
}

void main() {
  late _FakeEngine engine;
  late TorController controller;

  setUp(() {
    engine = _FakeEngine();
    controller = TorController(engine);
  });

  tearDown(() async {
    controller.dispose();
    await engine.close();
  });

  test('starts in the off phase', () {
    expect(controller.phase, TorPhase.off);
    expect(controller.isConnected, isFalse);
    expect(controller.socksPort, isNull);
  });

  test('start() moves to starting and calls the engine', () async {
    await controller.start();
    expect(engine.startCalls, 1);
    expect(controller.phase, TorPhase.starting);
  });

  test('mirrors the engine bootstrap → connected stream', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.bootstrapping, bootstrapPercent: 40));
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, TorPhase.bootstrapping);

    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9999));
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, TorPhase.connected);
    expect(controller.isConnected, isTrue);
    expect(controller.socksPort, 9999);
    expect(notifications, greaterThanOrEqualTo(3)); // starting + bootstrapping + connected
  });

  test('start() is a no-op while already connected (no second engine start)',
      () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isConnected, isTrue);

    await controller.start();
    expect(engine.startCalls, 1, reason: 'should not restart an already-up engine');
  });

  test('a start() failure lands in the error phase', () async {
    engine.throwOnStart = true;
    await controller.start();
    expect(controller.phase, TorPhase.error);
    expect(controller.status.message, contains('boom'));
  });

  test('an engine stream error becomes an error status', () async {
    await controller.start();
    engine._ctrl.addError(StateError('stream down'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, TorPhase.error);
  });

  test('stop() stops the engine and returns to off', () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);

    await controller.stop();
    expect(engine.stopCalls, 1);
    expect(controller.phase, TorPhase.off);
    expect(controller.socksPort, isNull);
  });

  test('start() after an error restarts the engine', () async {
    engine.throwOnStart = true;
    await controller.start();
    expect(controller.phase, TorPhase.error);

    engine.throwOnStart = false;
    await controller.start();
    expect(engine.startCalls, 2);
    expect(controller.phase, TorPhase.starting);
  });

  test('reconnectAfterResume holds the network and fully restarts the engine, '
      'then routes to the re-emitted connected status', () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isConnected, isTrue);

    await controller.reconnectAfterResume();
    // This hook fires only when the resume probe couldn't confirm the socket —
    // i.e. a wedged Arti after a suspend, which a wake can't heal (verified
    // on-device). So it does a full restart, held fail-closed while it rebuilds.
    expect(engine.reconnectCalls, 1);
    expect(engine.wakeCalls, 0, reason: 'a wedged Tor needs a fresh bootstrap, not a wake');
    expect(engine.startCalls, 1, reason: 'restart must not cold-start');
    expect(controller.phase, TorPhase.bootstrapping);
    expect(controller.isConnected, isFalse);

    // The native side rebuilds circuits and re-emits connected (new port).
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9777));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isConnected, isTrue);
    expect(controller.socksPort, 9777);
  });

  test('wakeFromBackground wakes the engine without changing status', () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);

    await controller.wakeFromBackground();
    expect(engine.wakeCalls, 1);
    expect(controller.isConnected, isTrue,
        reason: 'a wake keeps the live port — never holds fail-closed');
    expect(controller.socksPort, 9050);
  });

  test('wakeFromBackground is a no-op while off', () async {
    await controller.wakeFromBackground();
    expect(engine.wakeCalls, 0);
  });

  test('a wakeFromBackground failure is swallowed (best-effort, stays connected)',
      () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);

    engine.throwOnWake = true;
    await controller.wakeFromBackground(); // must not throw
    expect(engine.wakeCalls, 1);
    expect(controller.phase, TorPhase.connected,
        reason: 'the supervisor handles deeper recovery; a wake never errors out');
  });

  test('reconnectAfterResume is a no-op while off (Tor not the transport)',
      () async {
    await controller.reconnectAfterResume();
    expect(engine.reconnectCalls, 0);
    expect(controller.phase, TorPhase.off);
  });

  test('reconnectAfterResume is a no-op while a connect is already in progress',
      () async {
    await controller.start(); // phase: starting
    expect(controller.phase, TorPhase.starting);
    await controller.reconnectAfterResume();
    expect(engine.reconnectCalls, 0, reason: 'start already in flight');

    engine.emit(const TorStatus(phase: TorPhase.bootstrapping, bootstrapPercent: 20));
    await Future<void>.delayed(Duration.zero);
    await controller.reconnectAfterResume();
    expect(engine.reconnectCalls, 0, reason: 'still bootstrapping');
  });

  test('a reconnectAfterResume restart failure (from the error phase) lands '
      'back in error', () async {
    engine.throwOnStart = true;
    await controller.start(); // → error
    expect(controller.phase, TorPhase.error);
    engine.throwOnStart = false;

    engine.throwOnReconnect = true;
    await controller.reconnectAfterResume(); // error → full restart → reconnect throws
    expect(controller.phase, TorPhase.error);
    expect(controller.status.message, contains('reboom'));
  });

  test('forceRestart resets a connected-but-wedged engine and re-routes to the '
      're-emitted live port', () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isConnected, isTrue);

    await controller.forceRestart();
    expect(engine.reconnectCalls, 1);
    expect(engine.startCalls, 1, reason: 'force restart must not cold-start');
    expect(controller.phase, TorPhase.bootstrapping);
    expect(controller.isConnected, isFalse, reason: 'held fail-closed on reset');

    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9777));
    await Future<void>.delayed(Duration.zero);
    expect(controller.socksPort, 9777);
  });

  test('forceRestart is a no-op while off (Tor not the transport)', () async {
    await controller.forceRestart();
    expect(engine.reconnectCalls, 0);
    expect(controller.phase, TorPhase.off);
  });

  test('forceRestart is a no-op while a connect is already in progress',
      () async {
    await controller.start(); // phase: starting
    await controller.forceRestart();
    expect(engine.reconnectCalls, 0, reason: 'a reset would only churn it');
  });

  test('prepareForBackground idles the engine while connected', () async {
    await controller.start();
    engine.emit(const TorStatus(phase: TorPhase.connected, socksPort: 9050));
    await Future<void>.delayed(Duration.zero);

    await controller.prepareForBackground();
    expect(engine.prepareForBackgroundCalls, 1);
  });

  test('prepareForBackground is a no-op when not connected', () async {
    await controller.start(); // starting, not connected
    await controller.prepareForBackground();
    expect(engine.prepareForBackgroundCalls, 0);
  });
}
