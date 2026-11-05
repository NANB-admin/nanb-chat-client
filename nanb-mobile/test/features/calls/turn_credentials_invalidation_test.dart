import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/models/call_session.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';
import 'package:nanb_chat/features/calls/turn_credentials_invalidation.dart';

CallSession _ended(CallEndReason reason, {DateTime? connectedAt}) =>
    CallSession(
      callId: 'call-1',
      conversationId: 'convo',
      peerAccountId: 'peer',
      peerUsername: '@peer',
      peerDeviceId: 'dev',
      direction: CallDirection.outgoing,
      status: CallStatus.ended,
      mediaKind: CallMediaKind.audio,
      startedAt: DateTime.utc(2026, 1, 1),
      endReason: reason,
      connectedAt: connectedAt,
    );

void main() {
  test('a call that failed before reaching media drops the cached credential',
      () {
    expect(shouldDropTurnCredentials(_ended(CallEndReason.failed)), isTrue);
  });

  test('a call that failed after connecting keeps the cached credential', () {
    final ended =
        _ended(CallEndReason.failed, connectedAt: DateTime.utc(2026, 1, 1));
    expect(shouldDropTurnCredentials(ended), isFalse);
  });

  test('an unanswered call that was hung up keeps the cached credential', () {
    expect(shouldDropTurnCredentials(_ended(CallEndReason.hangup)), isFalse);
  });
}
