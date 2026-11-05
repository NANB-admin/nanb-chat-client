import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/core/push/push_token_provider.dart';
import 'package:nanb_chat/core/push/push_token_registrar.dart';

class _RecordingApi implements ApiClient {
  final List<({String platform, String token})> registered = [];
  int deleteCalls = 0;

  @override
  Future<void> registerPushToken({required String platform, required String token}) async {
    registered.add((platform: platform, token: token));
  }

  @override
  Future<void> deletePushToken() async { deleteCalls++; }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError(i.memberName.toString());
}

class _FakeProvider implements PushTokenProvider {
  _FakeProvider({
    this.initial,
    // ignore: unused_element_parameter
    this.platform = 'fcm',
  });
  String? initial;
  @override
  final String platform;
  final _refresh = StreamController<String>.broadcast();

  @override
  Future<String?> currentToken() async => initial;

  @override
  Stream<String> get onTokenRefresh => _refresh.stream;

  void emit(String t) => _refresh.add(t);
}

void main() {
  group('PushTokenRegistrar', () {
    test('bootstrap POSTs the initial token when non-null', () async {
      final api = _RecordingApi();
      final provider = _FakeProvider(initial: 'tok-1');
      final reg = PushTokenRegistrar(api: api, provider: provider);
      await reg.bootstrap();
      expect(api.registered, [(platform: 'fcm', token: 'tok-1')]);
    });

    test('bootstrap skips POST when token is null', () async {
      final api = _RecordingApi();
      final provider = _FakeProvider(initial: null);
      final reg = PushTokenRegistrar(api: api, provider: provider);
      await reg.bootstrap();
      expect(api.registered, isEmpty);
    });

    // "No token at all" must be distinguishable from "the POST failed": one is
    // fixed by a permission/opt-in change, the other by reconnecting. It used
    // to be entirely invisible — Settings rendered nothing for it.
    test('bootstrap reports having found no token when the platform has none',
        () async {
      final reg = PushTokenRegistrar(
          api: _RecordingApi(), provider: _FakeProvider(initial: null));
      await reg.bootstrap();
      expect(reg.lastFoundNoToken, isTrue);
      expect(reg.lastRegistrationSucceeded, isNull);
    });

    test('a token that registers clears the no-token state', () async {
      final reg = PushTokenRegistrar(
          api: _RecordingApi(), provider: _FakeProvider(initial: 'tok-1'));
      await reg.bootstrap();
      expect(reg.lastFoundNoToken, isFalse);
      expect(reg.lastRegistrationSucceeded, isTrue);
    });

    test('refresh emissions trigger POST calls', () async {
      final api = _RecordingApi();
      final provider = _FakeProvider(initial: null);
      final reg = PushTokenRegistrar(api: api, provider: provider);
      await reg.bootstrap();
      provider.emit('tok-rot-1');
      provider.emit('tok-rot-2');
      await Future<void>.delayed(Duration.zero);
      expect(api.registered.map((e) => e.token), ['tok-rot-1', 'tok-rot-2']);
    });

    test('dispose stops listening for refreshes', () async {
      final api = _RecordingApi();
      final provider = _FakeProvider(initial: null);
      final reg = PushTokenRegistrar(api: api, provider: provider);
      await reg.bootstrap();
      await reg.dispose();
      provider.emit('tok-after-dispose');
      await Future<void>.delayed(Duration.zero);
      expect(api.registered, isEmpty);
    });

    test('a re-bootstrap does not stack a second refresh listener', () async {
      // bootstrap() runs on every connect. Stacking listeners meant one token
      // rotation fired one POST per reconnect the app had ever made.
      final api = _RecordingApi();
      final provider = _FakeProvider(initial: null);
      final reg = PushTokenRegistrar(api: api, provider: provider);
      await reg.bootstrap();
      await reg.bootstrap();

      provider.emit('tok-rot');
      await Future<void>.delayed(Duration.zero);

      expect(api.registered.length, equals(1));
    });

    test('a landed registration is reported as reachable', () async {
      final api = _RecordingApi();
      final reg = PushTokenRegistrar(
          api: api, provider: _FakeProvider(initial: 'tok-1'));

      await reg.bootstrap();

      expect(reg.lastRegistrationSucceeded, isTrue);
    });

    test('a failed registration is reported as unreachable', () async {
      // Silence here is total — with no token on the server the device is never
      // pushed at all — so the failure must be visible, not just swallowed.
      final api = _FailingApi();
      final reg = PushTokenRegistrar(
          api: api, provider: _FakeProvider(initial: 'tok-1'));

      await reg.bootstrap();

      expect(reg.lastRegistrationSucceeded, isFalse);
    });

    test('reachability is unknown before any token is offered', () async {
      final reg = PushTokenRegistrar(
          api: _RecordingApi(), provider: _FakeProvider(initial: null));

      await reg.bootstrap();

      expect(reg.lastRegistrationSucceeded, isNull);
    });
  });
}

class _FailingApi implements ApiClient {
  @override
  Future<void> registerPushToken(
          {required String platform, required String token}) async =>
      throw StateError('offline');

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError(i.memberName.toString());
}
