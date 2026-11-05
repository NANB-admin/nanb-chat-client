import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/conversation_kind.dart';

void main() {
  group('ConversationKind', () {
    test('fromName resolves "oneToOne"', () {
      expect(ConversationKind.fromName('oneToOne'), ConversationKind.oneToOne);
    });

    test('fromName resolves "group"', () {
      expect(ConversationKind.fromName('group'), ConversationKind.group);
    });

    test('fromName throws on unknown value', () {
      expect(() => ConversationKind.fromName('flock'), throwsArgumentError);
    });
  });
}
