import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';

void main() {
  test('delete-for-me encodes with its wire name and the target', () {
    expect(const MessageControl.deleteForMe('env-1').encode(),
        '{"_control":"delete_for_me","target":"env-1"}');
  });

  test('delete-for-me round-trips its target', () {
    final decoded = MessageControl.tryDecode(
        const MessageControl.deleteForMe('env-1').encode());

    expect(decoded!.targetEnvelopeId, 'env-1');
  });

  test('delete-for-me decodes as a delete-for-me control', () {
    final decoded = MessageControl.tryDecode(
        const MessageControl.deleteForMe('env-1').encode());

    expect(decoded!.isDeleteForMe, isTrue);
  });

  test('delete-for-me is not mistaken for an unsend', () {
    final decoded = MessageControl.tryDecode(
        const MessageControl.deleteForMe('env-1').encode());

    expect(decoded!.isGroupDeleted, isFalse);
  });

  test('delete-for-me without a target is rejected', () {
    expect(MessageControl.tryDecode('{"_control":"delete_for_me"}'), isNull);
  });

  test('delete-for-me with an empty target is rejected', () {
    expect(
        MessageControl.tryDecode('{"_control":"delete_for_me","target":""}'),
        isNull);
  });

  test('group-deleted encodes as just its wire name', () {
    expect(const MessageControl.groupDeleted().encode(),
        '{"_control":"group_deleted"}');
  });

  test('group-deleted decodes as a group-deleted control', () {
    final decoded = MessageControl.tryDecode('{"_control":"group_deleted"}');

    expect(decoded!.isGroupDeleted, isTrue);
  });

  test('group-deleted is not a delete-for-me control', () {
    final decoded = MessageControl.tryDecode('{"_control":"group_deleted"}');

    expect(decoded!.isDeleteForMe, isFalse);
  });

  test('an unsend is neither delete-for-me nor group-deleted', () {
    const unsend = MessageControl.unsend('env-1');

    expect(unsend.isDeleteForMe || unsend.isGroupDeleted, isFalse);
  });

  test('an unknown control kind still decodes to null', () {
    expect(MessageControl.tryDecode('{"_control":"from_the_future"}'), isNull);
  });
}
