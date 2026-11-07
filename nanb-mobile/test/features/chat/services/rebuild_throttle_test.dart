import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';
import 'package:nanb_chat/features/chat/services/rebuild_throttle.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 11, 6, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('RebuildThrottle', () {
    late SecureStorage storage;
    late _Clock clock;
    late RebuildThrottle throttle;

    setUp(() {
      storage = SecureStorageInMemory();
      clock = _Clock();
      throttle = RebuildThrottle(storage: storage, clock: clock.call);
    });

    test('allows the first rebuild', () async {
      expect(await throttle.allows('c'), isTrue);
    });

    test('blocks a second rebuild within 45 seconds', () async {
      await throttle.record('c');
      clock.advance(const Duration(seconds: 44));

      expect(await throttle.allows('c'), isFalse);
    });

    test('allows a second rebuild after 45 seconds', () async {
      await throttle.record('c');
      clock.advance(const Duration(seconds: 45));

      expect(await throttle.allows('c'), isTrue);
    });

    test('a third rebuild waits two minutes', () async {
      await throttle.record('c');
      clock.advance(const Duration(seconds: 50));
      await throttle.record('c');
      clock.advance(const Duration(seconds: 119));

      expect(await throttle.allows('c'), isFalse);
    });

    test('the wait stops growing at fifteen minutes', () async {
      for (var i = 0; i < 8; i++) {
        await throttle.record('c');
        clock.advance(const Duration(minutes: 16));
      }

      expect(await throttle.allows('c'), isTrue);
    });

    test('says how long is left to wait', () async {
      await throttle.record('c');
      clock.advance(const Duration(seconds: 40));

      expect(await throttle.remainingWait('c'), const Duration(seconds: 5));
    });

    test('nothing is left to wait for a chat never rebuilt', () async {
      expect(await throttle.remainingWait('c'), Duration.zero);
    });

    test('the limit survives a restart', () async {
      // The old in-memory limit reset on every launch.
      await throttle.record('c');

      final restarted = RebuildThrottle(storage: storage, clock: clock.call);

      expect(await restarted.allows('c'), isFalse);
    });

    test('limits each chat separately', () async {
      await throttle.record('c');

      expect(await throttle.allows('other'), isTrue);
    });

    test('a successful decrypt ends the run', () async {
      await throttle.record('c');

      await throttle.clear('c');

      expect(await throttle.allows('c'), isTrue);
    });

    test('a quiet hour starts a new run at the shortest wait', () async {
      for (var i = 0; i < 4; i++) {
        await throttle.record('c');
        clock.advance(const Duration(minutes: 16));
      }
      clock.advance(const Duration(hours: 1));
      await throttle.record('c');
      clock.advance(const Duration(seconds: 46));

      expect(await throttle.allows('c'), isTrue);
    });

    test('evicts the oldest chat once full', () async {
      final small =
          RebuildThrottle(storage: storage, clock: clock.call, maxEntries: 1);
      await small.record('old');

      await small.record('new');

      expect(await small.allows('old'), isTrue);
    });

    test('treats an unreadable store as empty', () async {
      await storage.putString(RebuildThrottle.storageKey, 'not json');

      expect(
          await RebuildThrottle(storage: storage, clock: clock.call).allows('c'),
          isTrue);
    });
  });
}
