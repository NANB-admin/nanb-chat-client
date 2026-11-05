import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/firebase_messaging_facade.dart';
import 'package:nanb_chat/core/push/push_permission.dart';
import 'package:nanb_chat/core/push/push_token_provider_fcm.dart';

class _FakeFacade implements FirebaseMessagingFacade {
  // ignore: unused_element_parameter
  _FakeFacade({this.token, this.permissionGranted = true});
  String? token;
  bool permissionGranted;
  final _refresh = StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => _refresh.stream;

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<PushPermission> permissionStatus() async =>
      permissionGranted ? PushPermission.granted : PushPermission.denied;

  bool autoInit = true;
  int deleteTokenCalls = 0;

  @override
  Future<void> setAutoInitEnabled(bool enabled) async => autoInit = enabled;

  @override
  Future<void> deleteToken() async => deleteTokenCalls++;

  void emitRefresh(String newToken) => _refresh.add(newToken);
}

void main() {
  group('PushTokenProviderFcm', () {
    test('currentToken returns the facade token', () async {
      final facade = _FakeFacade(token: 'fcm-abc');
      final provider = PushTokenProviderFcm(facade: facade);
      expect(await provider.currentToken(), 'fcm-abc');
    });

    test('currentToken returns null when facade returns null', () async {
      final provider = PushTokenProviderFcm(facade: _FakeFacade(token: null));
      expect(await provider.currentToken(), isNull);
    });

    test('platform tag is "fcm"', () {
      final provider = PushTokenProviderFcm(facade: _FakeFacade());
      expect(provider.platform, 'fcm');
    });

    test('onTokenRefresh forwards facade refresh emissions', () async {
      final facade = _FakeFacade();
      final provider = PushTokenProviderFcm(facade: facade);
      final emitted = <String>[];
      final sub = provider.onTokenRefresh.listen(emitted.add);
      facade.emitRefresh('new-token-1');
      facade.emitRefresh('new-token-2');
      await Future<void>.delayed(Duration.zero);
      expect(emitted, ['new-token-1', 'new-token-2']);
      await sub.cancel();
    });
  });
}
