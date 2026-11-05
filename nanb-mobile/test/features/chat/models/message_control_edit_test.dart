import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';

void main() {
  const edit = MessageControl.edit(targetEnvelopeId: 'env-1', text: 'fixed');

  group('MessageControl.edit', () {
    test('round-trips the target', () {
      expect(MessageControl.tryDecode(edit.encode())!.targetEnvelopeId, 'env-1');
    });

    test('round-trips the new text', () {
      expect(MessageControl.tryDecode(edit.encode())!.editedText, 'fixed');
    });

    test('decodes as an edit', () {
      expect(MessageControl.tryDecode(edit.encode())!.isEdit, isTrue);
    });

    test('is not mistaken for a reaction', () {
      expect(MessageControl.tryDecode(edit.encode())!.isReaction, isFalse);
    });

    test('is rejected without a target', () {
      expect(MessageControl.tryDecode('{"_control":"edit","text":"x"}'), isNull);
    });

    test('is rejected with blank text', () {
      expect(
        MessageControl.tryDecode('{"_control":"edit","target":"e","text":"  "}'),
        isNull,
      );
    });
  });
}
