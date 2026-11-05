import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/catchup_timing.dart';

CatchupTiming timing({
  int envelopes = 10,
  int pages = 1,
  Duration fetch = const Duration(milliseconds: 100),
  Duration process = const Duration(milliseconds: 900),
  Duration total = const Duration(milliseconds: 1000),
  Duration slowest = Duration.zero,
  String slowestType = '',
}) =>
    CatchupTiming(
      envelopes: envelopes,
      pages: pages,
      fetch: fetch,
      process: process,
      total: total,
      slowest: slowest,
      slowestType: slowestType,
    );

void main() {
  group('CatchupTiming', () {
    test('an empty drain reports no backlog rather than a row of zeroes', () {
      expect(CatchupTiming.empty.summary, 'No backlog on the last catchup.');
    });

    test('divides local time by envelope count', () {
      // The per-message cost is the number that has to come down for a large
      // backlog to drain inside the budget.
      final t = timing(envelopes: 9, process: const Duration(milliseconds: 900));

      expect(t.perEnvelope, const Duration(milliseconds: 100));
    });

    test('does not divide by zero on an empty drain', () {
      expect(timing(envelopes: 0).perEnvelope, Duration.zero);
    });

    test('separates network time from local time', () {
      // The fork in the road: the server answers in single-digit ms, so a slow
      // drain is local unless the transport is at fault.
      final t = timing(
        fetch: const Duration(milliseconds: 120),
        process: const Duration(milliseconds: 1700),
      );

      expect(t.summary, contains('net 120ms'));
      expect(t.summary, contains('local 1.7s'));
    });

    test('renders sub-second durations in milliseconds', () {
      final t = timing(total: const Duration(milliseconds: 640));

      expect(t.summary, contains('640ms total'));
    });

    test('names the slowest envelope and its type', () {
      // One pathological envelope can dominate a drain; an average hides it.
      final t = timing(
        slowest: const Duration(milliseconds: 310),
        slowestType: 'mls_application',
      );

      expect(t.summary, contains('slowest 310ms mls_application'));
    });

    test('omits the slowest clause when no type was recorded', () {
      expect(timing().summary, isNot(contains('slowest')));
    });

    test('reports the page count only when it paged more than once', () {
      expect(timing(pages: 3).summary, contains('over 3 pages'));
      expect(timing(pages: 1).summary, isNot(contains('pages')));
    });

    test('singularises a one-message drain', () {
      expect(timing(envelopes: 1).summary, startsWith('1 msg ·'));
    });
  });
}
