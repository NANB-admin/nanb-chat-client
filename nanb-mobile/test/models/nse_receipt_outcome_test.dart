import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/nse_receipt_outcome.dart';

void main() {
  test('parses the stage the extension reached', () {
    final outcome = NseReceiptOutcome.fromJson({'stage': 'sent', 'at': 1000});

    expect(outcome!.stage, equals('sent'));
  });

  test('reads the timestamp as UTC seconds since the epoch', () {
    final outcome = NseReceiptOutcome.fromJson({'stage': 'sent', 'at': 1000});

    expect(outcome!.at, equals(DateTime.utc(1970, 1, 1, 0, 16, 40)));
  });

  test('a record with no stage is rejected', () {
    expect(NseReceiptOutcome.fromJson({'at': 1000}), isNull);
  });

  test('a record with no timestamp is rejected', () {
    expect(NseReceiptOutcome.fromJson({'stage': 'sent'}), isNull);
  });

  test('a 2xx send counts as delivered', () {
    final outcome =
        NseReceiptOutcome.fromJson({'stage': 'sent', 'at': 1, 'http': 200});

    expect(outcome!.delivered, isTrue);
  });

  test('a rejected send does not count as delivered', () {
    final outcome =
        NseReceiptOutcome.fromJson({'stage': 'sent', 'at': 1, 'http': 401});

    expect(outcome!.delivered, isFalse);
  });

  test('a send that never got an HTTP response is not delivered', () {
    // stage 'sent' only means the POST was attempted — with no response there
    // is no evidence the receipt landed.
    final outcome = NseReceiptOutcome.fromJson(
        {'stage': 'sent', 'at': 1, 'note': 'url-1009'});

    expect(outcome!.delivered, isFalse);
  });

  test('a skipped attempt is not delivered', () {
    final outcome = NseReceiptOutcome.fromJson({'stage': 'skiptor', 'at': 1});

    expect(outcome!.delivered, isFalse);
  });

  test('the summary pairs the stage with the HTTP status when there is one', () {
    final outcome =
        NseReceiptOutcome.fromJson({'stage': 'sent', 'at': 1, 'http': 202});

    expect(outcome!.summary, equals('sent · 202'));
  });

  test('the summary falls back to the note when there is no HTTP status', () {
    final outcome = NseReceiptOutcome.fromJson(
        {'stage': 'sent', 'at': 1, 'note': 'url-1009'});

    expect(outcome!.summary, equals('sent · url-1009'));
  });

  test('the summary is the bare stage when there is no detail', () {
    final outcome = NseReceiptOutcome.fromJson({'stage': 'nopeerkeys', 'at': 1});

    expect(outcome!.summary, equals('nopeerkeys'));
  });
}
