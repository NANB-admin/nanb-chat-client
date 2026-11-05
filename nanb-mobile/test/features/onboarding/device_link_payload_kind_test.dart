import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/device_kind.dart';
import 'package:nanb_chat/features/onboarding/device_link_payload.dart';

final _pk = List<int>.filled(32, 1);
final _xk = List<int>.filled(32, 2);

String _uri(String extra) {
  final pk = _pk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final xk = _xk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return 'nanb-link://device?id=h&pk=$pk&xk=$xk$extra';
}

void main() {
  test('a QR without kind parses as phone', () {
    expect(DeviceLinkPayload.parse(_uri('')).kind, DeviceKind.phone);
  });

  test('kind=web parses as web', () {
    expect(DeviceLinkPayload.parse(_uri('&kind=web')).kind, DeviceKind.web);
  });

  test('kind=phone parses as phone', () {
    expect(DeviceLinkPayload.parse(_uri('&kind=phone')).kind, DeviceKind.phone);
  });

  test('an unknown kind parses as phone', () {
    expect(DeviceLinkPayload.parse(_uri('&kind=fridge')).kind, DeviceKind.phone);
  });

  test('buildUri for a phone leaves the QR bytes unchanged', () {
    final uri = DeviceLinkPayload.buildUri(
        handleId: 'h', publicKey: _pk, x25519PublicKey: _xk);
    expect(uri, _uri(''));
  });

  test('buildUri for web appends kind=web', () {
    final uri = DeviceLinkPayload.buildUri(
        handleId: 'h',
        publicKey: _pk,
        x25519PublicKey: _xk,
        kind: DeviceKind.web);
    expect(uri, _uri('&kind=web'));
  });
}
