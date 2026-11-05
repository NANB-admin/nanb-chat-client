import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/onboarding/recovery_phrase.dart';

void main() {
  group('RecoveryPhrase', () {
    test('generate returns 12 words', () {
      final phrase = RecoveryPhrase.generate();
      expect(RecoveryPhrase.wordCount(phrase), equals(12));
    });

    test('legacy 24-word phrase still validates', () {
      const legacy =
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon abandon abandon art';
      expect(RecoveryPhrase.validate(legacy), isTrue);
      expect(RecoveryPhrase.isAcceptable(legacy), isTrue);
    });

    test('normalize lowercases and collapses whitespace', () {
      expect(
        RecoveryPhrase.normalize('  Correct  HORSE\nbattery   staple '),
        equals('correct horse battery staple'),
      );
    });

    test('normalize is identity for generated phrases', () {
      final phrase = RecoveryPhrase.generate();
      expect(RecoveryPhrase.normalize(phrase), equals(phrase));
    });

    test('toSeed is normalization-invariant (custom phrase round-trip)', () {
      const a = 'my eight word custom phrase about green turtles';
      const b = '  My  EIGHT word custom\nphrase about green TURTLES ';
      expect(RecoveryPhrase.toSeed(a), equals(RecoveryPhrase.toSeed(b)));
    });

    test('isAcceptable accepts a custom phrase of minCustomWords words', () {
      const custom = 'one two three four five six seven eight';
      expect(RecoveryPhrase.validate(custom), isFalse);
      expect(RecoveryPhrase.isAcceptable(custom), isTrue);
    });

    test('isAcceptable rejects short custom phrases', () {
      expect(RecoveryPhrase.isAcceptable('too few words here'), isFalse);
    });

    test('generated phrase validates', () {
      final phrase = RecoveryPhrase.generate();
      expect(RecoveryPhrase.validate(phrase), isTrue);
    });

    test('rejects garbage', () {
      expect(RecoveryPhrase.validate('not a phrase'), isFalse);
    });

    test('rejects empty string', () {
      expect(RecoveryPhrase.validate(''), isFalse);
    });

    test('toSeed is deterministic for the same phrase + passphrase', () {
      final phrase = RecoveryPhrase.generate();
      final s1 = RecoveryPhrase.toSeed(phrase);
      final s2 = RecoveryPhrase.toSeed(phrase);
      expect(s1, equals(s2));
    });

    test('toSeed differs across passphrases', () {
      final phrase = RecoveryPhrase.generate();
      final s1 = RecoveryPhrase.toSeed(phrase);
      final s2 = RecoveryPhrase.toSeed(phrase, passphrase: 'extra');
      expect(s1, isNot(equals(s2)));
    });

    test('two generated phrases differ', () {
      final a = RecoveryPhrase.generate();
      final b = RecoveryPhrase.generate();
      expect(a, isNot(equals(b)));
    });

    test('wordCount on empty string returns 0', () {
      expect(RecoveryPhrase.wordCount(''), equals(0));
      expect(RecoveryPhrase.wordCount('   '), equals(0));
    });

    test('wordCount handles extra whitespace', () {
      expect(RecoveryPhrase.wordCount('  one  two   three '), equals(3));
    });

    test('meetsCreationStrength accepts a generated BIP-39 phrase', () {
      expect(RecoveryPhrase.meetsCreationStrength(RecoveryPhrase.generate()),
          isTrue);
    });

    test('meetsCreationStrength accepts a long, varied custom phrase', () {
      const strong =
          'lantern voyage crimson pebble orbit thicket meadow anchor '
          'quiver saddle bramble twilight';
      expect(RecoveryPhrase.wordCount(strong),
          greaterThanOrEqualTo(RecoveryPhrase.minNewCustomWords));
      expect(RecoveryPhrase.meetsCreationStrength(strong), isTrue);
    });

    test('meetsCreationStrength rejects a custom phrase below the new floor', () {
      // 8 words satisfies the laxer restore rule but not creation.
      const eight = 'one two three four five six seven eight';
      expect(RecoveryPhrase.isAcceptable(eight), isTrue);
      expect(RecoveryPhrase.meetsCreationStrength(eight), isFalse);
    });

    test('meetsCreationStrength rejects a long but low-distinct custom phrase',
        () {
      const repeated = 'echo echo echo echo echo echo echo echo echo echo '
          'echo echo';
      expect(RecoveryPhrase.wordCount(repeated),
          greaterThanOrEqualTo(RecoveryPhrase.minNewCustomWords));
      expect(RecoveryPhrase.meetsCreationStrength(repeated), isFalse);
    });

    test('meetsCreationStrength rejects distinct single-letter tokens', () {
      // 12 words, 8 distinct single letters: clears the word/distinct counts
      // but carries almost no entropy, so the bit floor must reject it.
      const trivial = 'a b c d e f g h a a a a';
      expect(RecoveryPhrase.wordCount(trivial),
          greaterThanOrEqualTo(RecoveryPhrase.minNewCustomWords));
      expect(trivial.split(' ').toSet().length,
          greaterThanOrEqualTo(RecoveryPhrase.minNewCustomDistinctWords));
      expect(RecoveryPhrase.meetsCreationStrength(trivial), isFalse);
    });

    test('meetsCreationStrength rejects two-letter tokens dominating', () {
      const twoChar = 'ab cd ef gh ij kl mn op qr st uv wx';
      expect(RecoveryPhrase.wordCount(twoChar),
          greaterThanOrEqualTo(RecoveryPhrase.minNewCustomWords));
      expect(RecoveryPhrase.meetsCreationStrength(twoChar), isFalse);
    });

    test('meetsCreationStrength accepts many distinct short real words', () {
      // Short (3-letter) but genuinely distinct words clear the floor via the
      // word-entropy model, so legitimate phrases are not over-rejected.
      const shortWords = 'red fox blue jay owl cat dog pig ant bee elk cod';
      expect(RecoveryPhrase.meetsCreationStrength(shortWords), isTrue);
    });
  });
}
