import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/conversations_notifier.dart';

void main() {
  final rng = Random(42);

  group('fanoutJitterDelay (group co-delivery timing decorrelation)', () {
    test('no jitter for a single recipient (no co-delivery, no latency cost)',
        () {
      expect(ConversationsNotifier.fanoutJitterDelay(0, rng), Duration.zero);
      expect(ConversationsNotifier.fanoutJitterDelay(1, rng), Duration.zero);
    });

    test('multi-recipient draws stay within [0, 600ms]', () {
      var sawPositive = false;
      for (var i = 0; i < 500; i++) {
        final d = ConversationsNotifier.fanoutJitterDelay(5, rng);
        expect(d, greaterThanOrEqualTo(Duration.zero));
        expect(d, lessThanOrEqualTo(const Duration(milliseconds: 600)));
        if (d > Duration.zero) sawPositive = true;
      }
      expect(sawPositive, isTrue, reason: 'jitter should actually spread sends');
    });

    test('the spread is randomized (not a constant delay)', () {
      final seen = <int>{};
      for (var i = 0; i < 200; i++) {
        seen.add(ConversationsNotifier.fanoutJitterDelay(3, rng).inMilliseconds);
      }
      expect(seen.length, greaterThan(20),
          reason: 'distinct delays => decorrelated submit times');
    });
  });
}
