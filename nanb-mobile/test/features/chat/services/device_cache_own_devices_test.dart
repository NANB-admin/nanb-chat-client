import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/services/device_cache.dart';

class _MockApi extends Mock implements ApiClient {}

Device _device(String id) =>
    Device(deviceId: id, accountId: 'acc', devicePubKey: const [1]);

void main() {
  final t0 = DateTime.utc(2026, 11, 5, 9);
  late _MockApi api;
  late DeviceCache cache;

  setUp(() {
    api = _MockApi();
    cache = DeviceCache(api: api);
  });

  test('the first call fetches the own device list', () async {
    when(() => api.listDevices()).thenAnswer((_) async => [_device('a')]);

    final devices = await cache.myDevices(now: t0);

    expect(devices.map((d) => d.deviceId), ['a']);
  });

  test('a call within the max age reuses the cached list (no refetch)',
      () async {
    when(() => api.listDevices()).thenAnswer((_) async => [_device('a')]);
    await cache.myDevices(now: t0);

    await cache.myDevices(now: t0.add(const Duration(seconds: 30)));

    verify(() => api.listDevices()).called(1);
  });

  test('a call after the max age refetches, so a newly linked device appears',
      () async {
    var calls = 0;
    when(() => api.listDevices()).thenAnswer((_) async {
      calls++;
      return calls == 1 ? [_device('a')] : [_device('a'), _device('web')];
    });
    await cache.myDevices(now: t0);

    final later = await cache.myDevices(now: t0.add(const Duration(minutes: 3)));

    expect(later.map((d) => d.deviceId), ['a', 'web']);
  });

  test('when the refresh fails the previous list is kept, not emptied',
      () async {
    var calls = 0;
    when(() => api.listDevices()).thenAnswer((_) async {
      calls++;
      if (calls == 1) return [_device('a')];
      throw Exception('offline');
    });
    await cache.myDevices(now: t0);

    final later = await cache.myDevices(now: t0.add(const Duration(minutes: 3)));

    expect(later.map((d) => d.deviceId), ['a']);
  });

  test('a failed first fetch yields an empty list', () async {
    when(() => api.listDevices()).thenThrow(Exception('offline'));

    expect(await cache.myDevices(now: t0), isEmpty);
  });

  test('own devices are stale before the first fetch', () {
    expect(cache.myDevicesStale(now: t0), isTrue);
  });

  test('own devices are fresh right after a fetch', () async {
    when(() => api.listDevices()).thenAnswer((_) async => [_device('a')]);
    await cache.myDevices(now: t0);

    expect(cache.myDevicesStale(now: t0), isFalse);
  });

  test('clearMyDevices forces the next call to refetch', () async {
    when(() => api.listDevices()).thenAnswer((_) async => [_device('a')]);
    await cache.myDevices(now: t0);
    cache.clearMyDevices();

    await cache.myDevices(now: t0);

    verify(() => api.listDevices()).called(2);
  });

  test('refreshMyDevices refetches even when the cache is fresh', () async {
    when(() => api.listDevices()).thenAnswer((_) async => [_device('a')]);
    await cache.myDevices(now: t0);

    await cache.refreshMyDevices();

    verify(() => api.listDevices()).called(2);
  });
}
