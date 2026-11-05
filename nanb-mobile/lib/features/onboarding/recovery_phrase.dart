import 'package:bip39/bip39.dart' as bip39;

/// Helpers for the recovery phrase users save at sign-up.
///
/// Generated phrases are 12-word BIP-39 mnemonics (128 bits of entropy).
/// Users may also bring their own words ([isAcceptable]) — the seed is
/// PBKDF2-derived from the literal string, so any phrase restores as long
/// as it normalizes identically at sign-up and restore ([normalize]).
/// Pre-2026-06 accounts have 24-word phrases; [validate] and [toSeed]
/// accept every BIP-39 length, so they keep restoring unchanged.
class RecoveryPhrase {
  /// Minimum words to ACCEPT a custom (non-BIP-39) phrase on RESTORE. A floor,
  /// not a guarantee — a custom phrase is only as strong as the words chosen.
  /// Kept low so any legacy phrase a user already created keeps restoring; new
  /// phrases are held to the higher [minNewCustomWords] bar (see
  /// [meetsCreationStrength]).
  static const int minCustomWords = 8;

  /// Minimum words for a custom phrase created TODAY. Higher than
  /// [minCustomWords]: the phrase deterministically derives the identity keys,
  /// which never rotate, and BIP-39's KDF (PBKDF2, 2048 rounds) barely stretches
  /// a weak phrase — so a new phrase must carry real entropy. Restore stays lax
  /// so pre-existing phrases keep working.
  static const int minNewCustomWords = 12;

  /// Minimum DISTINCT words in a new custom phrase — blocks trivially
  /// low-entropy strings like one word repeated to hit the count.
  static const int minNewCustomDistinctWords = 8;

  /// Approximate entropy floor (in bits) a NEW custom phrase must clear on top
  /// of the word/distinct counts. The phrase deterministically derives the
  /// account's immutable identity key, and BIP-39's PBKDF2 (2048 rounds) barely
  /// stretches it, so the words themselves must resist an offline guess. 64
  /// bits is the widely-cited floor below which offline brute force is
  /// tractable — we hold new custom phrases to it. (Generated BIP-39 mnemonics
  /// carry 128+ bits and never reach this check; see [meetsCreationStrength].)
  static const double minNewCustomBits = 64;

  /// A distinct token only counts as a "substantive word" for the word-entropy
  /// estimate once it is at least this many characters. Single- and two-letter
  /// tokens carry almost no guess-resistance, so padding a phrase with them
  /// (e.g. `a b c d …`) earns no word-entropy credit.
  static const int minSubstantiveWordLength = 3;

  /// Conservative bits credited per distinct substantive word. Deliberately far
  /// below BIP-39's ~11 bits/word: it assumes a smart dictionary attacker with
  /// a small effective per-word search space, so clearing the floor takes real
  /// variety rather than a handful of guessable words.
  static const double bitsPerSubstantiveWord = 8;

  /// Returns a freshly generated 12-word phrase (128 bits of entropy).
  static String generate() => bip39.generateMnemonic(strength: 128);

  /// True if `phrase` is a syntactically valid BIP-39 mnemonic.
  static bool validate(String phrase) => bip39.validateMnemonic(normalize(phrase));

  /// True for phrases accepted at sign-up and restore: a valid BIP-39
  /// mnemonic (any standard length, incl. legacy 24-word) OR a custom
  /// phrase of at least [minCustomWords] words.
  static bool isAcceptable(String phrase) =>
      validate(phrase) || wordCount(phrase) >= minCustomWords;

  /// Whether `phrase` is strong enough to CREATE a new account with. A
  /// generated BIP-39 mnemonic always qualifies; a custom phrase must have at
  /// least [minNewCustomWords] words, at least [minNewCustomDistinctWords]
  /// distinct words, AND an estimated entropy of at least [minNewCustomBits]
  /// bits. Deliberately stricter than [isAcceptable] — restore must keep
  /// accepting any phrase that ever worked, but creation should not mint a
  /// weak one.
  static bool meetsCreationStrength(String phrase) {
    // A real BIP-39 mnemonic is the happy path: the standard word list already
    // guarantees its entropy, so it short-circuits here and never touches the
    // custom-phrase heuristic below (no regression risk for generated phrases).
    if (validate(phrase)) return true;

    final words =
        normalize(phrase).split(' ').where((w) => w.isNotEmpty).toList();
    // Length + distinct-count guards: block short phrases and strings padded
    // to length with a repeated word.
    if (words.length < minNewCustomWords) return false;
    final distinct = words.toSet();
    if (distinct.length < minNewCustomDistinctWords) return false;

    // Entropy floor. The count/distinct guards alone still admit trivially
    // low-entropy strings such as "a b c d e f g h a a a a" (12 words, 8
    // distinct single letters). Estimating bits and requiring a floor rejects
    // those without affecting the BIP-39 short-circuit above.
    return _estimateCustomBits(distinct) >= minNewCustomBits;
  }

  /// Rough entropy estimate (bits) for a custom phrase, computed from its
  /// DISTINCT tokens only so repetition cannot inflate it. Returns the larger
  /// of two conservative models:
  ///   • word model — distinct substantive (>= [minSubstantiveWordLength] char)
  ///     tokens x [bitsPerSubstantiveWord]; rewards having many distinct real
  ///     words even when they are short.
  ///   • character model — total characters across the distinct tokens x a
  ///     Shannon-style per-character estimate that grows with the character
  ///     classes used; rewards long/varied tokens.
  /// Taking the max keeps a genuinely strong short-word phrase (many distinct
  /// 3+ letter words) from being rejected while still failing single- and
  /// two-letter spam, which earns credit under neither model.
  static double _estimateCustomBits(Set<String> distinctWords) {
    final joined = distinctWords.join();
    final charBits = joined.length * _bitsPerChar(joined);
    final substantive = distinctWords
        .where((w) => w.length >= minSubstantiveWordLength)
        .length;
    final wordBits = substantive * bitsPerSubstantiveWord;
    return charBits > wordBits ? charBits : wordBits;
  }

  /// Conservative Shannon-style bits-per-character for `s`. The base (~1.5) is
  /// an upper bound on written-English entropy; extra character classes (digits
  /// or symbols, which survive [normalize] since it only lowercases) widen the
  /// effective alphabet and add a little more.
  static double _bitsPerChar(String s) {
    var hasDigit = false;
    var hasOther = false;
    for (final r in s.runes) {
      if (r >= 0x30 && r <= 0x39) {
        hasDigit = true;
      } else if (r < 0x61 || r > 0x7a) {
        hasOther = true;
      }
    }
    var bits = 1.5;
    if (hasDigit) bits += 0.3;
    if (hasOther) bits += 0.5;
    return bits;
  }

  /// Canonical form: trimmed, lowercase, single spaces. Sign-up and restore
  /// both derive the seed from THIS form, so a custom phrase survives
  /// differences in casing and whitespace. Identity for generated phrases.
  static String normalize(String phrase) =>
      phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  /// Derives the 64-byte seed from `phrase` (normalized first). Optional
  /// `passphrase` for an additional secret factor (off by default per
  /// Plan 1 design).
  static List<int> toSeed(String phrase, {String passphrase = ''}) {
    return bip39.mnemonicToSeed(normalize(phrase), passphrase: passphrase);
  }

  /// Convenience: `RecoveryPhrase.wordCount(phrase)` returns the word count
  /// of the trimmed phrase. Used when displaying confirmation prompts.
  static int wordCount(String phrase) {
    final trimmed = phrase.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).length;
  }
}
