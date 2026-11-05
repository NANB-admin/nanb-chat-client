import 'firebase_messaging_facade.dart';
import 'push_token_provider.dart';

/// Real `PushTokenProvider` implementation backed by Firebase Cloud
/// Messaging via the testable [FirebaseMessagingFacade] seam.
///
/// On the placeholder Firebase project (Task 3), `getToken()` returns null
/// — the registrar (Task 6) skips POSTing in that case.
class PushTokenProviderFcm implements PushTokenProvider {
  PushTokenProviderFcm({required FirebaseMessagingFacade facade})
      : _facade = facade;

  final FirebaseMessagingFacade _facade;

  @override
  String get platform => 'fcm';

  @override
  Future<String?> currentToken() => _facade.getToken();

  @override
  Stream<String> get onTokenRefresh => _facade.onTokenRefresh;
}
