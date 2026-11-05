import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/services/device_cache.dart';

class _MockApi extends Mock implements ApiClient {}

void main() {
  final t0 = DateTime.utc(2026, 11, 5, 9);
  late DeviceCache cache;

  setUp(() => cache = DeviceCache(api: _MockApi()));

  test('an account never cached is stale', () {
    expect(cache.peerDevicesStale('acc-1', now: t0), isTrue);
  });

  test('a list just recorded is fresh', () {
    cache.setPeerDevices('acc-1', const [], now: t0);

    expect(cache.peerDevicesStale('acc-1', now: t0), isFalse);
  });

  test('a list older than maxAge is stale', () {
    cache.setPeerDevices('acc-1', const [], now: t0);

    expect(
      cache.peerDevicesStale('acc-1',
          maxAge: const Duration(minutes: 2),
          now: t0.add(const Duration(minutes: 3))),
      isTrue,
    );
  });

  test('re-recording a list resets its age', () {
    cache.setPeerDevices('acc-1', const [], now: t0);
    cache.setPeerDevices('acc-1', const [],
        now: t0.add(const Duration(minutes: 3)));

    expect(
      cache.peerDevicesStale('acc-1',
          now: t0.add(const Duration(minutes: 4))),
      isFalse,
    );
  });

  test('clear() makes every account stale again', () {
    cache.setPeerDevices('acc-1', const [], now: t0);
    cache.clear();

    expect(cache.peerDevicesStale('acc-1', now: t0), isTrue);
  });
}
