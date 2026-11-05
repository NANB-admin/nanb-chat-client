import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/device.dart';
import 'package:nanb_chat/core/models/device_kind.dart';

Map<String, Object?> _base() => {
      'device_id': 'd1',
      'account_id': 'a1',
      'device_pub_key': <int>[1, 2],
    };

void main() {
  test('missing kind parses as phone (older server)', () {
    expect(Device.fromJson(_base()).kind, DeviceKind.phone);
  });

  test('kind "web" parses as web', () {
    final d = Device.fromJson({..._base(), 'kind': 'web'});
    expect(d.kind, DeviceKind.web);
  });

  test('unknown kind parses as phone', () {
    final d = Device.fromJson({..._base(), 'kind': 'toaster'});
    expect(d.kind, DeviceKind.phone);
  });

  test('missing linked_by_device_id parses as null', () {
    expect(Device.fromJson(_base()).linkedByDeviceId, isNull);
  });

  test('linked_by_device_id is read when present', () {
    final d = Device.fromJson({..._base(), 'linked_by_device_id': 'd0'});
    expect(d.linkedByDeviceId, 'd0');
  });

  test('missing expires_at parses as null', () {
    expect(Device.fromJson(_base()).expiresAt, isNull);
  });

  test('expires_at RFC3339 is parsed', () {
    final d = Device.fromJson({..._base(), 'expires_at': '2026-12-01T10:00:00Z'});
    expect(d.expiresAt, DateTime.utc(2026, 12, 1, 10));
  });

  test('null expires_at and linked_by_device_id parse as null', () {
    final d = Device.fromJson(
        {..._base(), 'expires_at': null, 'linked_by_device_id': null});
    expect(d.expiresAt, isNull);
  });
}
