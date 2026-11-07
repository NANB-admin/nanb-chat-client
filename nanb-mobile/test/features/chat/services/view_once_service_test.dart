import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/view_once_service.dart';

import 'state_sync_test_host.dart';

ChatMessage _viewOnce({required bool mine, DateTime? openedAt}) => ChatMessage(
      envelopeId: 'env-1',
      conversationId: stateConvoId,
      senderDeviceId: mine ? stateMyDevice : statePeerDevice,
      body: 'secret',
      serverTs: DateTime.utc(2026, 11, 7),
      mine: mine,
      clientMsgId: 'cid-1',
      viewOnce: true,
      viewOnceOpenedAt: openedAt,
    );

class _Harness {
  _Harness(ChatMessage m)
      : host = StateFakeHost(stateConvo(messages: [m])) {
    service = ViewOnceService(host, empty: (id, msg, at) async {
      emptied.add(msg.envelopeId);
    });
  }

  final StateFakeHost host;
  late final ViewOnceService service;
  final emptied = <String>[];

  Future<void> opened({required String by, String cid = 'cid-1'}) =>
      service.applyInbound(
        conversationId: stateConvoId,
        control: MessageControl.viewOnceOpened(cid),
        senderDeviceId: by,
        myDeviceId: stateMyDevice,
      );
}

void main() {
  test('our other device opened one we received: our copy is emptied', () async {
    final h = _Harness(_viewOnce(mine: false));

    await h.opened(by: stateSiblingDevice);

    expect(h.emptied, ['env-1']);
  });

  test('the peer opened one we sent: our copy shows opened', () async {
    final h = _Harness(_viewOnce(mine: true));

    await h.opened(by: statePeerDevice);

    expect(h.emptied, ['env-1']);
  });

  test('the peer cannot mark their own message opened for us', () async {
    final h = _Harness(_viewOnce(mine: false));

    await h.opened(by: statePeerDevice);

    expect(h.emptied, isEmpty);
  });

  test('an already opened message is left alone', () async {
    final h = _Harness(_viewOnce(mine: false, openedAt: DateTime.utc(2026)));

    await h.opened(by: stateSiblingDevice);

    expect(h.emptied, isEmpty);
  });

  test('an unknown message id does nothing', () async {
    final h = _Harness(_viewOnce(mine: false));

    await h.opened(by: stateSiblingDevice, cid: 'other');

    expect(h.emptied, isEmpty);
  });

  test('view_once_opened survives encode and decode', () {
    final decoded = MessageControl.tryDecode(
        const MessageControl.viewOnceOpened('cid-9').encode());

    expect(decoded!.isViewOnceOpened, isTrue);
    expect(decoded.targetEnvelopeId, 'cid-9');
  });
}
