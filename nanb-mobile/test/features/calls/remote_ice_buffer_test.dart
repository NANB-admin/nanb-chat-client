import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/calls/remote_ice_buffer.dart';

final _c1 = {'candidate': 'c1'};
final _c2 = {'candidate': 'c2'};

void main() {
  late List<Map<String, dynamic>> applied;
  late Set<String> rejecting;
  late RemoteIceBuffer buffer;

  setUp(() {
    applied = [];
    rejecting = {};
    buffer = RemoteIceBuffer(apply: (c) async {
      if (rejecting.contains(c['candidate'])) throw StateError('rejected');
      applied.add(c);
    });
  });

  test('a candidate added before release is not applied', () async {
    await buffer.add(_c1);

    expect(applied, isEmpty);
  });

  test('release applies buffered candidates in arrival order', () async {
    await buffer.add(_c1);
    await buffer.add(_c2);
    await buffer.release();

    expect(applied, [_c1, _c2]);
  });

  test('a candidate added after release is applied immediately', () async {
    await buffer.release();
    await buffer.add(_c1);

    expect(applied, [_c1]);
  });

  test('a rejected candidate neither throws nor blocks the next one', () async {
    rejecting.add('c1');
    await buffer.add(_c1);
    await buffer.add(_c2);
    await buffer.release();

    expect(applied, [_c2]);
  });

  test('hold buffers again until the next release', () async {
    await buffer.release();
    buffer.hold();
    await buffer.add(_c1);

    expect(applied, isEmpty);
  });

  test('clear drops buffered candidates', () async {
    await buffer.add(_c1);
    buffer.clear();
    await buffer.release();

    expect(applied, isEmpty);
  });
}
