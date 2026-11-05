/// Wakeup-push platform abstraction. Plan 9 wires
/// firebase_messaging / flutter_apns_only into this interface.
abstract class PushTokenProvider {
  Future<String?> currentToken();

  /// Reports the push platform tag the server expects: "apns" or "fcm".
  String get platform;

  /// Stream of refreshed tokens. Implementations that don't auto-refresh
  /// (e.g., the stub) emit nothing.
  Stream<String> get onTokenRefresh;
}

/// Stub for tests + dev — always returns null.
class PushTokenProviderStub implements PushTokenProvider {
  PushTokenProviderStub({this.platform = 'fcm'});

  @override
  final String platform;

  @override
  Future<String?> currentToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();
}
