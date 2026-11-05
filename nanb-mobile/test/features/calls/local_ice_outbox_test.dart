import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/local_ice_outbox.dart';

final _c1 = {'candidate': 'c1'};
final _c2 = {'candidate': 'c2'};
final _c3 = {'candidate': 'c3'};

void main() {
  late List<List<Map<String, dynamic>>> sent;
  late Completer<void>? gate;
  late bool failNext;
  late LocalIceOutbox outbox;

  setUp(() {
    sent = [];
    gate = null;
    failNext = false;
    outbox = LocalIceOutbox(send: (batch) async {
      sent.add(batch);
      if (failNext) {
        failNext = false;
        throw StateError('send failed');
      }
      final g = gate;
      if (g != null) await g.future;
    });
  });

  test('candidates added before release are not sent', () async {
    outbox.add(_c1);
    await pumpEventQueue();

    expect(sent, isEmpty);
  });

  test('release sends everything held as one batch', () async {
    outbox.add(_c1);
    outbox.add(_c2);
    outbox.release();
    await pumpEventQueue();

    expect(sent, [
      [_c1, _c2]
    ]);
  });

  test('a candidate added while released is sent straight away', () async {
    outbox.release();
    outbox.add(_c1);
    await pumpEventQueue();

    expect(sent, [
      [_c1]
    ]);
  });

  test('candidates added during an in-flight send are coalesced into the next '
      'batch', () async {
    gate = Completer<void>();
    outbox.release();
    outbox.add(_c1);
    await pumpEventQueue();
    outbox.add(_c2);
    outbox.add(_c3);
    gate!.complete();
    await pumpEventQueue();

    expect(sent, [
      [_c1],
      [_c2, _c3]
    ]);
  });

  test('a failed send does not stop later candidates', () async {
    outbox.release();
    failNext = true;
    outbox.add(_c1);
    await pumpEventQueue();
    outbox.add(_c2);
    await pumpEventQueue();

    expect(sent.last, [_c2]);
  });

  test('hold stops sending until the next release', () async {
    outbox.release();
    outbox.hold();
    outbox.add(_c1);
    await pumpEventQueue();

    expect(sent, isEmpty);
  });

  test('clear drops held candidates', () async {
    outbox.add(_c1);
    outbox.clear();
    outbox.release();
    await pumpEventQueue();

    expect(sent, isEmpty);
  });
}
