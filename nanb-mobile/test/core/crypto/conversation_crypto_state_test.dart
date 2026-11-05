import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/crypto/conversation_crypto_state.dart';

ConversationCryptoState _state({
  String id = 'c',
  int sendCounter = 0,
  List<int>? sendChainKey,
  int recvCounter = 0,
  List<int>? recvChainKey,
}) {
  return ConversationCryptoState(
    conversationId: id,
    sendCounter: sendCounter,
    sendChainKey: sendChainKey ?? List<int>.filled(32, 1),
    recvCounter: recvCounter,
    recvChainKey: recvChainKey ?? List<int>.filled(32, 2),
  );
}

void main() {
  group('ConversationCryptoState', () {
    test('copyWith updates only provided fields', () {
      final base = _state();
      final next = base.copyWith(sendCounter: 5);
      expect(next.sendCounter, equals(5));
      expect(next.sendChainKey, equals(base.sendChainKey));
      expect(next.recvCounter, equals(base.recvCounter));
      expect(next.conversationId, equals(base.conversationId));
    });

    test('copyWith preserves all fields when nothing is provided', () {
      final base = _state(sendCounter: 7, recvCounter: 3);
      expect(base.copyWith(), equals(base));
    });

    test('equality + hashCode are consistent for equal instances', () {
      final a = _state(sendCounter: 9);
      final b = _state(sendCounter: 9);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different sendCounter means inequality', () {
      expect(_state(sendCounter: 0), isNot(equals(_state(sendCounter: 1))));
    });

    test('different chain key means inequality', () {
      expect(
        _state(sendChainKey: List.filled(32, 1)),
        isNot(equals(_state(sendChainKey: List.filled(32, 2)))),
      );
    });

    test('identical reference is equal to itself (short-circuit)', () {
      final s = _state();
      expect(s, equals(s));
    });
  });
}
