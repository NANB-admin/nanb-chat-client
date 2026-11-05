import 'dart:convert';

/// The notification payload for an incoming-call notification. When that
/// notification's full-screen intent (or a tap) launches the app, the app
/// decodes this to ring IMMEDIATELY from the payload (caller + conversation)
/// instead of waiting to reconnect + catch up + decrypt the E2EE invite.
///
/// A non-call notification's payload is a bare `conversationId` (used as a
/// deep-link), so [decode] returns null for those — the caller then treats the
/// raw string as a conversation id.
class CallLaunchPayload {
  const CallLaunchPayload({required this.conversationId, required this.caller});

  final String conversationId;
  final String caller;

  /// The payload string [LocalNotifications.showCall] attaches.
  static String encode(String conversationId, String caller) =>
      jsonEncode({'k': 'call', 'c': conversationId, 'n': caller});

  /// Parses a call-launch payload, or null if [payload] is a bare conversation
  /// id (an ordinary message-notification deep-link) or otherwise not ours.
  static CallLaunchPayload? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['k'] == 'call' && decoded['c'] is String) {
        return CallLaunchPayload(
          conversationId: decoded['c'] as String,
          caller: decoded['n'] is String ? decoded['n'] as String : '',
        );
      }
    } catch (_) {
      // Not JSON → a bare conversationId deep-link, not a call.
    }
    return null;
  }
}
