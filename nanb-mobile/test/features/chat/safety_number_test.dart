import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/safety_number.dart';

void main() {
  group('SafetyNumber.compute', () {
    // Regression: SHA-256 (32 bytes) only yields 30 digits, so requesting 60
    // used to throw a RangeError on substring → the number never rendered.
    test('returns exactly 60 decimal digits for two 32-byte identity keys',
        () async {
      final mine = List<int>.generate(32, (i) => i);
      final peer = List<int>.generate(32, (i) => (200 - i) & 0xff);
      final number = await SafetyNumber.compute(mineKey: mine, peerKey: peer);
      expect(number.length, 60);
      expect(RegExp(r'^[0-9]{60}$').hasMatch(number), isTrue,
          reason: 'must be 60 plain decimal digits');
    });

    test('both participants compute the SAME number regardless of arg order',
        () async {
      final a = List<int>.generate(32, (i) => i * 3 & 0xff);
      final b = List<int>.generate(32, (i) => 255 - i);
      final fromA = await SafetyNumber.compute(mineKey: a, peerKey: b);
      final fromB = await SafetyNumber.compute(mineKey: b, peerKey: a);
      expect(fromA, fromB);
      expect(fromA.length, 60);
    });

    test('different keys give a different number', () async {
      final a = List<int>.generate(32, (i) => i);
      final b = List<int>.generate(32, (i) => i);
      final c = List<int>.generate(32, (i) => i + 1);
      expect(await SafetyNumber.compute(mineKey: a, peerKey: b),
          isNot(await SafetyNumber.compute(mineKey: a, peerKey: c)));
    });

    test('empty key → empty string (the "not available yet" sentinel)',
        () async {
      expect(await SafetyNumber.compute(mineKey: const [], peerKey: const [1, 2, 3]), '');
      expect(await SafetyNumber.compute(mineKey: const [1, 2, 3], peerKey: const []), '');
    });
  });

  group('SafetyNumber.split', () {
    test('splits 60 digits into 12 groups of 5', () {
      final number = '0' * 60;
      final groups = SafetyNumber.split(number);
      expect(groups.length, 12);
      expect(groups.every((g) => g.length == 5), isTrue);
    });
  });
}
