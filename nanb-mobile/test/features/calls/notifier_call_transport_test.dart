import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/jwt_session.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/calls/models/call_signal.dart';
import 'package:nanb_chat/features/calls/notifier_call_transport.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/onboarding/session_repository.dart';

class _FakeNotifier extends ChangeNotifier implements ConversationsNotifier {
  final List<(String, CallSignal, String?)> sent = [];

  /// Per send: the directed device (if any) and whether it fanned out.
  final List<(String?, bool)> targets = [];

  @override
  Future<void> sendCallSignal(String conversationId, CallSignal signal,
      {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) async {
    sent.add((conversationId, signal, pushKind));
    targets.add((toDeviceId, allPeerDevices));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _session = JwtSession(
  accountId: 'me-acc',
  deviceId: 'my-dev',
  jwt: 'jwt',
  username: 'me',
);

void main() {
  late _FakeNotifier notifier;
  late SessionRepository sessions;
  late NotifierCallTransport transport;

  setUp(() async {
    notifier = _FakeNotifier();
    sessions = SessionRepository(SecureStorageInMemory());
    await sessions.save(_session);
    transport = NotifierCallTransport(notifier: () => notifier, sessions: sessions);
  });

  String oneToOne() => Conversation.oneToOneId('me-acc', 'peer-acc');

  test('sendToDevice routes to sendCallSignal on the 1:1 conversation', () async {
    await transport.sendToDevice(
      toAccountId: 'peer-acc',
      toDeviceId: 'peer-dev',
      signal: CallSignal.offer(callId: 'c1', sdp: 'SDP'),
    );
    final (cid, sig, kind) = notifier.sent.single;
    expect(cid, oneToOne());
    expect(sig.type, CallSignalType.offer);
    expect(sig.sdp, 'SDP');
    expect(kind, isNull, reason: 'only the invite carries a call push hint');
  });

  test('sendInvite carries the call push hint; cancel does not', () async {
    await transport.sendInvite(
      toAccountId: 'peer-acc',
      signal: CallSignal.invite(
        callId: 'c1',
        mediaKind: CallMediaKind.audio,
        fromDeviceId: 'my-dev',
      ),
    );
    await transport.sendToAllDevices(
      toAccountId: 'peer-acc',
      signal: CallSignal.cancel('c1'),
    );
    expect(notifier.sent.length, 2);
    expect(notifier.sent.every((e) => e.$1 == oneToOne()), isTrue);
    expect(notifier.sent.map((e) => e.$2.type),
        [CallSignalType.invite, CallSignalType.cancel]);
    // The ring rides a 'call' push; the cancel doesn't.
    expect(notifier.sent[0].$3, 'call');
    expect(notifier.sent[1].$3, isNull);
  });

  test('the invite rings every peer device', () async {
    await transport.sendInvite(
      toAccountId: 'peer-acc',
      signal: CallSignal.invite(
        callId: 'c1',
        mediaKind: CallMediaKind.audio,
        fromDeviceId: 'my-dev',
      ),
    );
    expect(notifier.targets.single, (null, true));
  });

  test('sendToDevice addresses the named device', () async {
    await transport.sendToDevice(
      toAccountId: 'peer-acc',
      toDeviceId: 'peer-dev',
      signal: CallSignal.offer(callId: 'c1', sdp: 'SDP'),
    );
    expect(notifier.targets.single, ('peer-dev', false));
  });

  test('sendToAllDevices reaches every peer device', () async {
    await transport.sendToAllDevices(
      toAccountId: 'peer-acc',
      signal: CallSignal.cancel('c1'),
    );
    expect(notifier.targets.single, (null, true));
  });

  test('with no active session nothing is sent', () async {
    final empty = NotifierCallTransport(
      notifier: () => notifier,
      sessions: SessionRepository(SecureStorageInMemory()),
    );
    await empty.sendToDevice(
      toAccountId: 'peer-acc',
      toDeviceId: 'peer-dev',
      signal: CallSignal.ringing('c1'),
    );
    expect(notifier.sent, isEmpty);
  });
}
