import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';

void main() {
  test('a set group-avatar control round-trips its descriptor', () {
    final decoded = MessageControl.tryDecode(
      const MessageControl.groupAvatar(avatarJson: '{"mid":"m1"}').encode(),
    );

    expect(decoded!.isGroupAvatar, isTrue);
    expect(decoded.groupAvatarJson, '{"mid":"m1"}');
  });

  test('a set group-avatar control is not flagged as a removal', () {
    final decoded = MessageControl.tryDecode(
      const MessageControl.groupAvatar(avatarJson: '{"mid":"m1"}').encode(),
    );

    expect(decoded!.groupAvatarRemove, isFalse);
  });

  test('a clear group-avatar control round-trips as a removal', () {
    final decoded = MessageControl.tryDecode(
      const MessageControl.groupAvatar(remove: true).encode(),
    );

    expect(decoded!.groupAvatarRemove, isTrue);
  });

  test('a group-avatar control with an empty descriptor is rejected', () {
    expect(
      MessageControl.tryDecode('{"_control":"group_avatar","avatar":""}'),
      isNull,
    );
  });

  test('other controls are not group-avatar controls', () {
    expect(const MessageControl.unsend('e1').isGroupAvatar, isFalse);
  });
}
