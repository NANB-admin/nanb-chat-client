import 'dart:math';

/// A random, hard-to-guess call id (128 bits of CSPRNG, hex). Correlates every
/// signal in a single call. Injected into [CallController] so tests can make it
/// deterministic.
String newCallId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
