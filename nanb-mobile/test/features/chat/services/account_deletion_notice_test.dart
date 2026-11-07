import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/services/account_deletion_notice.dart';

import 'state_sync_test_host.dart';

class _SendingHost extends StateFakeHost {
  _SendingHost(super.convo, {this.sendThrows = false});

  final bool sendThrows;
  final sent = <({String id, String body, bool allPeerDevices})>[];

  @override
  Future<void> sendControl(String conversationId, String body,
      {String? pushKind, String? toDeviceId, bool allPeerDevices = false}) async {
    if (sendThrows) throw StateError('offline');
    sent.add((id: conversationId, body: body, allPeerDevices: allPeerDevices));
  }
}

Future<void> _inbound(AccountDeletionNotice notice, String sender) =>
    notice.applyInbound(
      conversationId: stateConvoId,
      control: const MessageControl.accountDeleted(),
      senderDeviceId: sender,
      myDeviceId: stateMyDevice,
    );

void main() {
  group('telling contacts', () {
    test('each 1:1 peer gets account_deleted', () async {
      final host = _SendingHost(stateConvo());

      await AccountDeletionNotice(host).notifyContacts();

      expect(MessageControl.tryDecode(host.sent.single.body)!.isAccountDeleted,
          isTrue);
    });

    test('it goes to every device of the peer', () async {
      final host = _SendingHost(stateConvo());

      await AccountDeletionNotice(host).notifyContacts();

      expect(host.sent.single.allPeerDevices, isTrue);
    });

    test('groups are not told this way', () async {
      final host = _SendingHost(stateGroupConvo());

      await AccountDeletionNotice(host).notifyContacts();

      expect(host.sent, isEmpty);
    });

    test('a chat it cannot reach is counted, not fatal', () async {
      final host = _SendingHost(stateConvo(), sendThrows: true);

      expect(await AccountDeletionNotice(host).notifyContacts(), 1);
    });
  });

  group('receiving it', () {
    test('from the peer deletes the chat', () async {
      final host = StateFakeHost(stateConvo());

      await _inbound(AccountDeletionNotice(host), statePeerDevice);

      expect(host.deletedConversations, [stateConvoId]);
    });

    test('from one of our own devices is ignored', () async {
      final host = StateFakeHost(stateConvo());

      await _inbound(AccountDeletionNotice(host), stateSiblingDevice);

      expect(host.deletedConversations, isEmpty);
    });

    test('in a group is ignored', () async {
      final host = StateFakeHost(stateGroupConvo());

      await _inbound(AccountDeletionNotice(host), statePeerDevice);

      expect(host.deletedConversations, isEmpty);
    });

    test('for a chat we no longer have does nothing', () async {
      final host = StateFakeHost(null);

      await _inbound(AccountDeletionNotice(host), statePeerDevice);

      expect(host.deletedConversations, isEmpty);
    });
  });

  test('account_deleted survives encode and decode', () {
    final decoded =
        MessageControl.tryDecode(const MessageControl.accountDeleted().encode());

    expect(decoded!.isAccountDeleted, isTrue);
  });
}
