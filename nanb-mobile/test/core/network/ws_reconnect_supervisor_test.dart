import 'dart:async';
import 'dart:convert' show base64Url, jsonEncode, utf8;
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/api_error.dart';
import 'package:nanb_chat/core/models/envelope.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/network/connection_state.dart';
import 'package:nanb_chat/core/network/ws_client.dart';
import 'package:nanb_chat/core/network/ws_connection_event.dart';
import 'package:nanb_chat/core/network/ws_reconnect_supervisor.dart';

/// Test double for `WsClient`. Records connect/disconnect calls; tests can
/// push envelopes (unused here; the supervisor doesn't read them) and can
/// close the channel to simulate a drop via `closeServer()`.
class _FakeWs implements WsClient {
  @override
  void sendEphemeral(Map<String, dynamic> frame) {}

  @override
  bool sendAckFrame(List<String> envelopeIds) => false;

  @override
  bool get isConnected => false;

  /// Default: no socket, so the notifier falls back to HTTP — preserving the
  /// pre-existing behaviour of every test that doesn't care about the socket
  /// drain path.
  @override
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    DateTime? since,
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();

  @override
  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();
  StreamController<Envelope> _ctrl = StreamController<Envelope>.broadcast();
  final _disc = StreamController<void>.broadcast();
  bool connected = false;
  int connectCalls = 0;
  int disconnectCalls = 0;
  String? lastJwt;
  Object? connectError;
  bool alwaysThrowOnConnect = false;

  @override
  Stream<Envelope> get envelopes => _ctrl.stream;

  @override
  Stream<void> get disconnects => _disc.stream;

  @override
  Future<void> connect(String jwt) async {
    connectCalls++;
    lastJwt = jwt;
    if (alwaysThrowOnConnect) throw StateError('always fail');
    if (connectError != null) {
      final e = connectError;
      connectError = null;
      throw e!;
    }
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }

  int probeCalls = 0;
  bool probeResult = true; // pong by default (socket alive)
  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async {
    probeCalls++;
    return probeResult;
  }

  Future<void> closeServer() async {
    await _ctrl.close();
    _ctrl = StreamController<Envelope>.broadcast();
    connected = false;
    _disc.add(null); // the connection died underneath the client
  }
}

String _makeJwt(int? expEpochSeconds) {
  String b64url(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  final header = b64url('{"alg":"EdDSA","typ":"JWT"}');
  final claims = expEpochSeconds == null
      ? <String, dynamic>{'sub': 'acc'}
      : <String, dynamic>{'sub': 'acc', 'exp': expEpochSeconds};
  final payload = b64url(jsonEncode(claims));
  return '$header.$payload.sig';
}

class _FakeSessionSource {
  JwtSession session = const JwtSession(
    accountId: 'acc-1',
    deviceId: 'dev-1',
    jwt: 'aGVhZGVy.eyJzdWIiOiJhY2MtMSIsImV4cCI6OTk5OTk5OTk5OX0.c2ln',
    username: 'alice',
  );
  int refreshCalls = 0;
  Object? refreshError;

  Future<JwtSession> refresh() async {
    refreshCalls++;
    if (refreshError != null) {
      final e = refreshError;
      refreshError = null;
      throw e!;
    }
    final exp = (DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
    session = JwtSession(
      accountId: session.accountId,
      deviceId: session.deviceId,
      jwt: _makeJwt(exp),
      username: session.username,
    );
    return session;
  }
}

class _FakeDelay {
  final List<Duration> recorded = [];
  Future<void> call(Duration d) async {
    recorded.add(d);
    await Future<void>.value();
  }
}

/// Like a real Future.delayed, but each pending future is exposed so tests
/// can complete or cancel it manually. Resolves nothing on its own.
class _ControllableDelay {
  final List<Completer<void>> _pending = [];
  final List<Duration> recorded = [];

  Future<void> call(Duration d) {
    recorded.add(d);
    final c = Completer<void>();
    _pending.add(c);
    return c.future;
  }

  void completeAll() {
    for (final c in _pending) {
      if (!c.isCompleted) c.complete();
    }
    _pending.clear();
  }

  int get pendingCount => _pending.where((c) => !c.isCompleted).length;
}

/// A WsClient whose `connect()` blocks until the test releases it. Used to
/// test single-flight semantics during an in-flight attempt.
class _BlockingWs implements WsClient {
  @override
  void sendEphemeral(Map<String, dynamic> frame) {}

  @override
  bool sendAckFrame(List<String> envelopeIds) => false;

  @override
  bool get isConnected => false;

  /// Default: no socket, so the notifier falls back to HTTP — preserving the
  /// pre-existing behaviour of every test that doesn't care about the socket
  /// drain path.
  @override
  Future<List<Envelope>> catchupOverSocket(
    String clientRef, {
    int? limit,
    DateTime? since,
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();

  @override
  Future<({String envelopeId, DateTime serverTs})> sendAndAwaitAck(
    Map<String, dynamic> frame,
    String clientRef, {
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      throw const WsNotConnectedException();
  _BlockingWs(this.gate);
  final Completer<void> gate;
  final _ctrl = StreamController<Envelope>.broadcast();

  @override
  Stream<Envelope> get envelopes => _ctrl.stream;

  @override
  Stream<void> get disconnects => const Stream<void>.empty();

  @override
  Future<void> connect(String jwt) async {
    await gate.future;
  }

  @override
  Future<bool> probe({Duration timeout = const Duration(seconds: 5)}) async =>
      false;

  @override
  Future<void> disconnect() async {}
}

void main() {
  late _FakeWs ws;
  late _FakeSessionSource session;
  late _FakeDelay delay;
  late _ControllableDelay controllableDelay;

  setUp(() {
    ws = _FakeWs();
    session = _FakeSessionSource();
    delay = _FakeDelay();
  });

  WsReconnectSupervisor buildSupervisor() => WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
      );

  WsReconnectSupervisor buildSupervisorWithControllableDelay() {
    controllableDelay = _ControllableDelay();
    return WsReconnectSupervisor(
      wsClient: ws,
      sessionLoader: () async => session.session,
      refreshSession: session.refresh,
      random: Random(0),
      delay: controllableDelay.call,
    );
  }

  group('happy path', () {
    test('start transitions connecting -> connected and emits Reconnected', () async {
      final s = buildSupervisor();
      final events = <WsConnectionEvent>[];
      final sub = s.events.listen(events.add);

      expect(s.state, ConnectionState.connecting);
      await s.start();
      await Future<void>.value(); // Let event propagate
      expect(s.state, ConnectionState.connected);
      expect(ws.connectCalls, 1);
      expect(ws.lastJwt, session.session.jwt);
      expect(events, hasLength(1));
      expect(events.first, isA<Reconnected>());

      await s.stop();
      await sub.cancel();
    });
  });

  group('backoff retry on ws.connect() failure', () {
    test('connect throw -> reconnecting -> backoff -> retry succeeds', () async {
      ws.connectError = StateError('first attempt fails');
      final s = buildSupervisor();
      final states = <ConnectionState>[];
      s.addListener(() => states.add(s.state));

      await s.start();
      expect(ws.connectCalls, 2);
      expect(s.state, ConnectionState.connected);
      expect(states, [ConnectionState.reconnecting, ConnectionState.connecting, ConnectionState.connected]);
      expect(delay.recorded, hasLength(1));

      await s.stop();
    });

    test('backoff curve: attempts 1..6 delays bracket 1s, 2s, 4s, 8s, 16s, 30s (+/-25% jitter)', () async {
      ws.alwaysThrowOnConnect = true;
      late final WsReconnectSupervisor s;
      s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(42),
        delay: (d) async {
          delay.recorded.add(d);
          if (delay.recorded.length >= 6) {
            await s.stop();
          }
        },
      );
      await s.start();

      const bases = [1, 2, 4, 8, 16, 30];
      expect(delay.recorded, hasLength(6));
      for (var i = 0; i < 6; i++) {
        final base = bases[i] * 1000; // ms
        final ms = delay.recorded[i].inMilliseconds;
        expect(ms, greaterThanOrEqualTo((base * 0.75).round()));
        expect(ms, lessThanOrEqualTo((base * 1.25).round()));
      }
    });
  });

  group('repeated-failure transport recovery', () {
    test('fires onRepeatedFailure at the threshold, then once per further '
        'threshold of failures', () async {
      ws.alwaysThrowOnConnect = true;
      var recoverCalls = 0;
      var recordedDelays = 0;
      late final WsReconnectSupervisor s;
      s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        onRepeatedFailure: () async => recoverCalls++,
        repeatedFailureThreshold: 3,
        delay: (d) async {
          recordedDelays++;
          if (recordedDelays >= 7) await s.stop();
        },
      );

      await s.start();
      // 7 failed attempts → counter reaches 3 and 6 (fire twice); the 7th
      // attempt's stop() short-circuits before its own recovery check.
      expect(recoverCalls, 2);
    });

    test('does not fire below the threshold', () async {
      ws.alwaysThrowOnConnect = true;
      var recoverCalls = 0;
      var recordedDelays = 0;
      late final WsReconnectSupervisor s;
      s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        onRepeatedFailure: () async => recoverCalls++,
        repeatedFailureThreshold: 3,
        delay: (d) async {
          recordedDelays++;
          if (recordedDelays >= 2) await s.stop();
        },
      );

      await s.start();
      expect(recoverCalls, 0);
    });
  });

  group('drop handling', () {
    test('attempt counter resets to 0 on successful connect', () async {
      // First start: 1 failed attempt then success -> counter would be 1.
      // We assert this indirectly: after the success, a close-and-reconnect
      // should backoff from n=0 again (base 1s), not from n=1 (base 2s).
      final s = buildSupervisor();
      ws.connectError = StateError('fail #1');
      await s.start();
      expect(delay.recorded, hasLength(1));
      expect(s.state, ConnectionState.connected);

      // Simulate a drop. After the WS closes, the supervisor should kick the
      // reconnect loop. The first delay of the new arc should bracket 1s
      // (not 2s) because the counter reset on connect.
      delay.recorded.clear();
      ws.connectError = StateError('fail #2');
      await ws.closeServer();
      // Yield microtasks so the onDone listener fires and the loop runs the
      // failed attempt + delay.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(delay.recorded, hasLength(1));
      final ms = delay.recorded.first.inMilliseconds;
      expect(ms, greaterThanOrEqualTo(750));
      expect(ms, lessThanOrEqualTo(1250));
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('WS onDone while connected transitions to reconnecting and re-attempts', () async {
      final s = buildSupervisor();
      final states = <ConnectionState>[];
      s.addListener(() => states.add(s.state));
      await s.start();
      expect(s.state, ConnectionState.connected);
      final initialCalls = ws.connectCalls;

      await ws.closeServer();
      // Yield microtasks so the onDone listener fires, then the reconnect loop
      // runs, fails once, delays, retries, and succeeds.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(states.contains(ConnectionState.reconnecting), isTrue, reason: 'states: $states');
      expect(ws.connectCalls, greaterThan(initialCalls));
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });
  });

  group('JWT expiry gating', () {
    test('refresh is NOT called when exp is far in the future', () async {
      final farFuture = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(
        accountId: 'a', deviceId: 'd', jwt: _makeJwt(farFuture), username: 'alice',
      );
      final s = buildSupervisor();
      await s.start();
      expect(session.refreshCalls, 0);
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('refresh IS called when exp is in the past', () async {
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(
        accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice',
      );
      final s = buildSupervisor();
      await s.start();
      expect(session.refreshCalls, 1);
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('refresh IS called when exp is within the next 60 seconds', () async {
      final soon = DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(
        accountId: 'a', deviceId: 'd', jwt: _makeJwt(soon), username: 'alice',
      );
      final s = buildSupervisor();
      await s.start();
      expect(session.refreshCalls, 1);
      await s.stop();
    });

    test('null jwtExpiry (malformed) triggers refresh', () async {
      session.session = const JwtSession(
        accountId: 'a', deviceId: 'd', jwt: 'not-a-jwt', username: 'alice',
      );
      final s = buildSupervisor();
      await s.start();
      expect(session.refreshCalls, 1);
      await s.stop();
    });
  });

  group('refresh failure triage', () {
    test('transient ApiError (network) retries with backoff instead of signing out',
        () async {
      // signedOut triggers clearLocalData() downstream — a server that's
      // merely unreachable at the 24h token boundary must NOT wipe the
      // device. This exact cascade destroyed two devices' local state live.
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = const ApiError(code: 'network', message: 'connection refused');
      final s = buildSupervisor();
      final events = <WsConnectionEvent>[];
      final sub = s.events.listen(events.add);

      await s.start();
      await Future<void>.value();

      // First attempt failed transiently -> backoff -> second attempt's
      // refresh succeeds -> connected. Never signedOut.
      expect(s.state, ConnectionState.connected);
      expect(events.whereType<SignedOut>(), isEmpty);
      expect(session.refreshCalls, 2);
      expect(delay.recorded, hasLength(1));

      await s.stop();
      await sub.cancel();
    });

    test('definitive rejection (device_not_found) signs out', () async {
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = const ApiError(
          code: 'device_not_found', message: 'device not found', statusCode: 404);
      final s = buildSupervisor();

      await s.start();

      expect(s.state, ConnectionState.signedOut);
      expect(ws.connectCalls, 0);
      await s.stop();
    });
  });

  group('ws handshake rejection (revoked device)', () {
    test('rejected handshake + refresh says device gone -> signs out + wipes',
        () async {
      // Default session: a still-fresh JWT (far-future expiry), so the
      // near-expiry refresh is skipped and the handshake is attempted. The
      // server rejects it (revoked device — a recovery-phrase takeover on
      // another phone). The probe refresh then returns device_not_found, so
      // the supervisor signs out (which wipes downstream).
      ws.connectError = StateError('handshake rejected: revoked');
      session.refreshError = const ApiError(
          code: 'device_not_found', message: 'device not found', statusCode: 401);
      final s = buildSupervisor();
      final events = <WsConnectionEvent>[];
      final sub = s.events.listen(events.add);

      await s.start();
      await Future<void>.value();
      expect(s.state, ConnectionState.signedOut);
      expect(events.whereType<SignedOut>(), isNotEmpty);
      expect(ws.connectCalls, 1,
          reason: 'the handshake is attempted before the revocation probe');

      await s.stop();
      await sub.cancel();
    });

    test('transient handshake failure (device still valid) -> retries, no wipe',
        () async {
      // connectError fires once then clears; the probe refresh SUCCEEDS (device
      // still valid), so the supervisor must retry and reconnect, NOT sign out
      // — wiping an E2EE device over a transient blip is unrecoverable.
      ws.connectError = StateError('transient handshake blip');
      final s = buildSupervisor();

      await s.start();
      await Future<void>.value();
      expect(s.state, ConnectionState.connected);
      expect(ws.connectCalls, 2, reason: 'failed once, retried, connected');

      await s.stop();
    });
  });

  group('refresh failure -> signedOut', () {
    test('refresh throwing transitions to signedOut + emits SignedOut event', () async {
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = StateError('challenge_invalid');
      final s = buildSupervisor();
      final events = <WsConnectionEvent>[];
      final sub = s.events.listen(events.add);

      await s.start();
      await Future<void>.value(); // Let event propagate
      expect(s.state, ConnectionState.signedOut);
      expect(events, hasLength(1));
      expect(events.first, isA<SignedOut>());
      expect(ws.connectCalls, 0);

      await s.stop();
      await sub.cancel();
    });

    test('clearSignedOut leaves the terminal state so onboarding can proceed',
        () async {
      // Onboarding replaces the credentials outright, so the server's "this
      // device is unknown" verdict no longer applies. Without an escape the
      // state is unrecoverable in-process and the router keeps forcing
      // /welcome — the user had to force-quit the app after creating an
      // account. `connecting`, not `connected`: no socket exists yet.
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = StateError('challenge_invalid');
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.signedOut);

      s.clearSignedOut();

      expect(s.state, ConnectionState.connecting);
      await s.stop();
    });

    test('clearSignedOut is a no-op when not signed out', () async {
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.connected);

      s.clearSignedOut();

      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('after signedOut, stop() and start() restarts cleanly', () async {
      final past = DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = StateError('bad');
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.signedOut);

      session.refreshError = null;
      final priorRefreshCalls = session.refreshCalls;
      await s.stop();
      await s.start();
      // After stop+start, the supervisor restarts. The session is still
      // expired, so it'll refresh (succeeds this time) and connect.
      expect(s.state, ConnectionState.connected);
      expect(session.refreshCalls, priorRefreshCalls + 1);
      await s.stop();
    });
  });

  group('onAppResumed', () {
    test('in reconnecting: cancels pending delay and retries immediately', () async {
      ws.connectError = StateError('first fail');
      final s = buildSupervisorWithControllableDelay();

      // Kick off start() but don't await — it'll suspend at the delay.
      final pending = s.start();
      // Yield until the failed attempt registered the delay.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.reconnecting);
      expect(controllableDelay.pendingCount, 1);

      s.onAppResumed();
      await pending;

      expect(s.state, ConnectionState.connected);
      expect(ws.connectCalls, 2);
    });

    test('in connected: no-op', () async {
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.connected);
      final priorConnectCalls = ws.connectCalls;
      s.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      expect(ws.connectCalls, priorConnectCalls);
      await s.stop();
    });

    test('in connecting (mid-attempt): no-op (single-flight)', () async {
      final gate = Completer<void>();
      final blocking = _BlockingWs(gate);
      final s = WsReconnectSupervisor(
        wsClient: blocking,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
      );

      final starting = s.start();
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.connecting);

      s.onAppResumed(); // no-op while an attempt is in flight

      gate.complete();
      await starting;
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('after signedOut: no-op', () async {
      final past = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = StateError('bad');
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.signedOut);

      session.refreshError = null;
      s.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.signedOut);
      expect(ws.connectCalls, 0);
    });
  });

  group('verifyConnectionOrReconnect', () {
    test('connected + probe succeeds: keeps the live socket (no reconnect)',
        () async {
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.connected);
      ws.probeResult = true; // pong → socket is alive

      await s.verifyConnectionOrReconnect();
      await pumpEventQueue();

      expect(ws.probeCalls, 1);
      expect(ws.disconnectCalls, 0); // socket kept — NO reconnect
      expect(ws.connectCalls, 1);
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('connected + probe fails: drops the dead socket and reconnects',
        () async {
      final s = buildSupervisor();
      await s.start();
      ws.probeResult = false; // no pong → socket is dead

      await s.verifyConnectionOrReconnect();
      await pumpEventQueue();

      expect(ws.probeCalls, 1);
      expect(ws.disconnectCalls, 1); // dead socket torn down
      expect(ws.connectCalls, 2); // and reconnected
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('reconnecting: skips the backoff without probing', () async {
      ws.connectError = StateError('first fail');
      final s = buildSupervisorWithControllableDelay();
      final pending = s.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.reconnecting);

      await s.verifyConnectionOrReconnect();
      await pending;

      expect(ws.probeCalls, 0); // not connected → nothing to probe
      expect(s.state, ConnectionState.connected);
      await s.stop();
    });

    test('connected + probe alive: does NOT fire the transport-recovery hook',
        () async {
      var hookCalls = 0;
      final s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
        onResumeTransportUnconfirmed: () async => hookCalls++,
      );
      await s.start();
      ws.probeResult = true; // pong → socket alive

      await s.verifyConnectionOrReconnect();
      await pumpEventQueue();

      // A surviving socket must NOT trigger a Tor re-bootstrap on resume.
      expect(hookCalls, 0);
      expect(ws.disconnectCalls, 0);
      await s.stop();
    });

    test('connected + probe dead: fires the transport-recovery hook', () async {
      var hookCalls = 0;
      final s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
        onResumeTransportUnconfirmed: () async => hookCalls++,
      );
      await s.start();
      ws.probeResult = false; // no pong → socket dead

      await s.verifyConnectionOrReconnect();
      await pumpEventQueue();

      // Dead socket on resume → recover the transport beneath it (restart Tor)
      // AND reconnect the WS.
      expect(hookCalls, 1);
      expect(ws.disconnectCalls, 1);
      await s.stop();
    });

    test('reconnecting on resume: fires the transport-recovery hook', () async {
      var hookCalls = 0;
      ws.connectError = StateError('first fail');
      controllableDelay = _ControllableDelay();
      final s = WsReconnectSupervisor(
        wsClient: ws,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: controllableDelay.call,
        onResumeTransportUnconfirmed: () async => hookCalls++,
      );
      final pending = s.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.reconnecting);

      await s.verifyConnectionOrReconnect();
      await pending;

      expect(hookCalls, 1);
      await s.stop();
    });

    test('connecting (mid-attempt) on resume: fires the transport-recovery hook',
        () async {
      var hookCalls = 0;
      final gate = Completer<void>();
      final blocking = _BlockingWs(gate);
      final s = WsReconnectSupervisor(
        wsClient: blocking,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
        onResumeTransportUnconfirmed: () async => hookCalls++,
      );
      final starting = s.start();
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.connecting);

      await s.verifyConnectionOrReconnect();

      // Eager recovery even with no live socket to probe — don't wait for the
      // in-flight attempt to time out.
      expect(hookCalls, 1);

      gate.complete();
      await starting;
      await s.stop();
    });
  });

  group('forceReconnect', () {
    test('in connected: drops the (possibly half-open) socket and reconnects',
        () async {
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.connected);
      expect(ws.connectCalls, 1);
      expect(ws.disconnectCalls, 0);

      s.forceReconnect();
      await pumpEventQueue();

      // Old socket torn down, fresh one established.
      expect(ws.disconnectCalls, 1);
      expect(ws.connectCalls, 2);
      expect(s.state, ConnectionState.connected);

      await s.stop();
    });

    test('in reconnecting: skips the backoff and retries immediately', () async {
      ws.connectError = StateError('first fail');
      final s = buildSupervisorWithControllableDelay();

      final pending = s.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.reconnecting);
      expect(controllableDelay.pendingCount, 1);

      s.forceReconnect();
      await pending;

      expect(s.state, ConnectionState.connected);
      expect(ws.connectCalls, 2);
    });

    test('after signedOut: no-op (never re-dials a revoked device)', () async {
      final past = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      session.session = JwtSession(accountId: 'a', deviceId: 'd', jwt: _makeJwt(past), username: 'alice');
      session.refreshError = StateError('bad');
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.signedOut);

      s.forceReconnect();
      await pumpEventQueue();

      expect(s.state, ConnectionState.signedOut);
      expect(ws.disconnectCalls, 0);
      expect(ws.connectCalls, 0);
    });
  });

  group('stop / restart / events', () {
    test('stop() mid-attempt cancels cleanly', () async {
      final gate = Completer<void>();
      final blocking = _BlockingWs(gate);
      final s = WsReconnectSupervisor(
        wsClient: blocking,
        sessionLoader: () async => session.session,
        refreshSession: session.refresh,
        random: Random(0),
        delay: delay.call,
      );
      final starting = s.start();
      await Future<void>.delayed(Duration.zero);
      expect(s.state, ConnectionState.connecting);
      await s.stop();
      gate.complete();
      await starting;
      // After stop(), state may have moved to connected (the connect resolved)
      // but the supervisor is no longer "started" so further work doesn't happen.
      final priorConnect = ws.connectCalls; // 0 (used a _BlockingWs, not the shared `ws`)
      s.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      expect(ws.connectCalls, priorConnect);
    });

    test('start() -> stop() -> start() works (counter reset)', () async {
      ws.connectError = StateError('first');
      final s = buildSupervisor();
      await s.start();
      expect(s.state, ConnectionState.connected);
      await s.stop();

      delay.recorded.clear();
      ws.connectError = StateError('second arc fail');
      await s.start();
      expect(delay.recorded, hasLength(1));
      final ms = delay.recorded.first.inMilliseconds;
      expect(ms, greaterThanOrEqualTo(750));
      expect(ms, lessThanOrEqualTo(1250));
      await s.stop();
    });

    test('events stream emits Reconnected exactly once per successful attempt', () async {
      final s = buildSupervisor();
      final events = <WsConnectionEvent>[];
      final sub = s.events.listen(events.add);

      await s.start();
      // Give the broadcast event a microtask to land.
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<Reconnected>(), hasLength(1));

      await ws.closeServer();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<Reconnected>().length, greaterThanOrEqualTo(2));

      await s.stop();
      await sub.cancel();
    });
  });
}
