import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/view_once_header.dart';

void main() {
  test('split returns the body after the marker', () {
    expect(ViewOnceHeader.split('${ViewOnceHeader.prefix}hello'), 'hello');
  });

  test('split returns null for an ordinary body', () {
    expect(ViewOnceHeader.split('hello'), isNull);
  });

  test('an unopened message lasts 14 days', () {
    final sent = DateTime.utc(2026, 11, 7);
    expect(ViewOnceHeader.expiry(sent, null), sent.add(const Duration(days: 14)));
  });

  test('a shorter disappearing time wins', () {
    final sent = DateTime.utc(2026, 11, 7);
    final soon = sent.add(const Duration(hours: 1));
    expect(ViewOnceHeader.expiry(sent, soon), soon);
  });

  test('a longer disappearing time is capped at 14 days', () {
    final sent = DateTime.utc(2026, 11, 7);
    final late = sent.add(const Duration(days: 90));
    expect(ViewOnceHeader.expiry(sent, late), sent.add(const Duration(days: 14)));
  });
}
