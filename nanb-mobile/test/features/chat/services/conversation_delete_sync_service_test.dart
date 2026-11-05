import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/conversation_delete_sync_service.dart';

import 'state_sync_test_host.dart';

class _Harness {
  _Harness({StateFakeHost? host, this.sendBehaviour = _Send.sealAndFinish})
      : host = host ?? StateFakeHost(stateConvo()) {
    service = ConversationDeleteSyncService(
      this.host,
      sendSelfControlNotifyingSealed: (id, body, onSealed) async {
        order.add('send');
        bodies.add(body);
        switch (sendBehaviour) {
          case _Send.sealAndFinish:
            onSealed();
          case _Send.throws:
            throw StateError('offline');
          case _Send.hang:
            await Future<void>.delayed(const Duration(seconds: 5));
        }
      },
      deleteConversation: (id) async {
        order.add('delete');
        this.host.convo = null;
      },
      sealTimeout: const Duration(milliseconds: 50),
    );
  }

  final StateFakeHost host;
  final _Send sendBehaviour;
  final order = <String>[];
  final bodies = <String>[];
  late final ConversationDeleteSyncService service;

  Future<void> inbound({String sender = stateSiblingDevice}) =>
      service.applyInbound(
        conversationId: stateConvoId,
        control: const MessageControl.conversationDeleted(),
        senderDeviceId: sender,
        myDeviceId: stateMyDevice,
      );
}

enum _Send { sealAndFinish, throws, hang }

void main() {
  test('deleting a 1:1 sends conversation_deleted to our other devices',
      () async {
    final h = _Harness();

    await h.service.deleteAndSync(stateConvoId);

    expect(MessageControl.tryDecode(h.bodies.single)!.isConversationDeleted,
        isTrue);
  });

  test('the control is minted before the local delete', () async {
    final h = _Harness();

    await h.service.deleteAndSync(stateConvoId);

    expect(h.order, ['send', 'delete']);
  });

  test('the local delete still happens when the send fails', () async {
    final h = _Harness(sendBehaviour: _Send.throws);

    await h.service.deleteAndSync(stateConvoId);

    expect(h.order, ['send', 'delete']);
  });

  test('a send that never seals does not hold the delete hostage', () async {
    final h = _Harness(sendBehaviour: _Send.hang);

    await h.service.deleteAndSync(stateConvoId);

    expect(h.order, ['send', 'delete']);
  });

  test('a group is deleted locally without any control', () async {
    final h = _Harness(
        host: StateFakeHost(stateGroupConvo()));

    await h.service.deleteAndSync(stateConvoId);

    expect(h.bodies, isEmpty);
  });

  test('an inbound delete from our own device deletes the 1:1', () async {
    final h = _Harness();

    await h.inbound();

    expect(h.host.deletedConversations, [stateConvoId]);
  });

  test('an inbound delete sends nothing', () async {
    final h = _Harness();

    await h.inbound();

    expect(h.host.selfControls, isEmpty);
  });

  test('an inbound delete from the peer is ignored', () async {
    final h = _Harness();

    await h.inbound(sender: statePeerDevice);

    expect(h.host.deletedConversations, isEmpty);
  });

  test('an inbound delete for a group is ignored', () async {
    final h = _Harness(
        host: StateFakeHost(stateGroupConvo()));

    await h.inbound();

    expect(h.host.deletedConversations, isEmpty);
  });

  test('an inbound delete for an already-gone conversation is a no-op',
      () async {
    final h = _Harness(host: StateFakeHost(null));

    await h.inbound();

    expect(h.host.deletedConversations, isEmpty);
  });
}
