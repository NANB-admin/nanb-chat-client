import 'push_token_provider.dart';
import 'voip_push_channel.dart';

/// [PushTokenProvider] for the iOS PushKit token, so the SAME
/// [PushTokenRegistrar] machinery registers it (and re-registers it on every
/// connect, which is what repairs a registration that failed while offline).
///
/// Registered under its own platform so the server files it separately: an
/// iPhone holds TWO tokens at once — the FCM-backed ALERT token for message
/// wakeups, and this one for the CallKit ring — reached over different
/// transports. Storing one over the other would silence whichever registered
/// first.
///
/// Off iOS the channel yields nothing, so the registrar simply finds no token
/// and skips — Android rings from its own FCM data wakeup.
class VoipPushTokenProvider implements PushTokenProvider {
  VoipPushTokenProvider({required VoipPushChannel channel}) : _channel = channel;

  final VoipPushChannel _channel;

  /// Must match `push.PlatformVoip` on the server.
  @override
  String get platform => 'apns_voip';

  @override
  Future<String?> currentToken() => _channel.currentToken();

  @override
  Stream<String> get onTokenRefresh => _channel.tokens;
}
