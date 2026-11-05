/// Where the time went in the last catchup drain.
///
/// Exists because "catchup takes a couple of seconds" is unactionable on its
/// own: the server serves a full page in single-digit milliseconds, so the cost
/// is entirely on the device — but it could be the network round trip, the
/// per-envelope decrypt through the native CoreCrypto bridge, or the SQLCipher
/// writes, and those have completely different fixes. Release builds silence
/// every `print`/`debugPrint`, so this has to be surfaced as state, not a log.
///
/// [fetch] and [process] are measured on the same drain, so `fetch + process`
/// approximates [total] (the remainder is bookkeeping between pages).
///
/// They no longer add up quite that cleanly on the FIRST page: its fetch is
/// started before the MLS reconcile gate and runs concurrently with it, so
/// [total] — which now spans the gate wait too — can exceed `fetch + process`
/// by however long reconcile held things up. A [fetch] that stays flat while
/// [total] grows is the signature of a slow reconcile, not a slow network.
class CatchupTiming {
  const CatchupTiming({
    required this.envelopes,
    required this.pages,
    required this.fetch,
    required this.process,
    required this.total,
    required this.slowest,
    required this.slowestType,
    this.silentFailures = 0,
  });

  /// An empty drain — nothing fetched, nothing to report.
  static const CatchupTiming empty = CatchupTiming(
    envelopes: 0,
    pages: 0,
    fetch: Duration.zero,
    process: Duration.zero,
    total: Duration.zero,
    slowest: Duration.zero,
    slowestType: '',
  );

  /// Envelopes actually processed (after de-duplicating re-delivered ones).
  final int envelopes;

  /// Catchup pages fetched.
  final int pages;

  /// Total time inside `POST /messages/catchup` calls.
  final Duration fetch;

  /// Total time decrypting + persisting envelopes.
  final Duration process;

  /// Wall clock for the whole drain.
  final Duration total;

  /// The single slowest envelope, and its type. One pathological envelope (a
  /// wedged group, an oversized media record) can dominate a drain, and an
  /// average would hide it completely.
  final Duration slowest;
  final String slowestType;

  /// Envelopes that failed INSIDE a receiver during this drain.
  ///
  /// The receivers swallow their own decrypt errors, so the drain counts them
  /// as successes and its failure diagnostic stays empty — a device can be
  /// re-failing the same envelopes on every launch with nothing anywhere
  /// saying so. That is exactly how 24 undecryptable envelopes went unnoticed
  /// for a day while burning ~900ms of every catchup.
  final int silentFailures;

  bool get isEmpty => envelopes == 0 && total == Duration.zero;

  /// Mean cost per envelope — the number that has to come down for a large
  /// backlog to drain inside the budget.
  Duration get perEnvelope => envelopes == 0
      ? Duration.zero
      : Duration(microseconds: process.inMicroseconds ~/ envelopes);

  /// One line for the diagnostics screen, e.g.
  /// `43 msgs · 1.9s (net 120ms · local 1.7s · 40ms/msg) · slowest 310ms mls_application`
  String get summary {
    if (isEmpty) return 'No backlog on the last catchup.';
    final parts = StringBuffer()
      ..write('$envelopes msg${envelopes == 1 ? '' : 's'}')
      ..write(pages > 1 ? ' over $pages pages' : '')
      ..write(' · ${_ms(total)} total')
      ..write(' (net ${_ms(fetch)} · local ${_ms(process)}')
      ..write(' · ${_ms(perEnvelope)}/msg)');
    if (slowestType.isNotEmpty) {
      parts.write(' · slowest ${_ms(slowest)} $slowestType');
    }
    if (silentFailures > 0) {
      parts.write(' · $silentFailures undecryptable');
    }
    return parts.toString();
  }

  static String _ms(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
}
