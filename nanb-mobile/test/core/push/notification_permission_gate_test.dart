import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/notification_permission_gate.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

class _FakeSeam implements NotificationPermissionSeam {
  _FakeSeam({this.granted = true, this.throwOnRequest = false});

  bool granted;
  bool throwOnRequest;
  int requestCalls = 0;

  @override
  Future<bool> request() async {
    requestCalls++;
    if (throwOnRequest) {
      throw StateError('seam failed');
    }
    return granted;
  }
}

void main() {
  group('NotificationPermissionGate.requestIfFirstTime', () {
    test('invokes the seam on the first call', () async {
      final seam = _FakeSeam();
      final storage = SecureStorageInMemory();
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      expect(seam.requestCalls, 1);
    });

    test('persists the prompted flag after the seam call', () async {
      final seam = _FakeSeam();
      final storage = SecureStorageInMemory();
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      expect(
        await storage.getString(NotificationPermissionGate.storageKey),
        'true',
      );
    });

    test('does not re-invoke the seam once the flag is set', () async {
      final seam = _FakeSeam();
      final storage = SecureStorageInMemory();
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      await gate.requestIfFirstTime();
      await gate.requestIfFirstTime();
      expect(seam.requestCalls, 1);
    });

    test('marks prompted even when the user denies', () async {
      final seam = _FakeSeam(granted: false);
      final storage = SecureStorageInMemory();
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      expect(
        await storage.getString(NotificationPermissionGate.storageKey),
        'true',
        reason: 'denial still counts as prompted — we never re-spam',
      );
    });

    test('marks prompted even when the seam throws', () async {
      final seam = _FakeSeam(throwOnRequest: true);
      final storage = SecureStorageInMemory();
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await expectLater(gate.requestIfFirstTime(), throwsA(isA<StateError>()));
      expect(
        await storage.getString(NotificationPermissionGate.storageKey),
        'true',
        reason: 'seam failure should not cause infinite retries',
      );
    });

    test('skips the seam entirely when prior session set the flag', () async {
      final seam = _FakeSeam();
      final storage = SecureStorageInMemory();
      await storage.putString(NotificationPermissionGate.storageKey, 'true');
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      expect(seam.requestCalls, 0);
    });

    test('a stale pre-v2 flag does not suppress the first real prompt', () async {
      final seam = _FakeSeam();
      final storage = SecureStorageInMemory();
      // Old builds (Firebase-off on iOS) persisted this legacy key via a no-op
      // stub seam; it must NOT suppress the first FCM-capable permission prompt.
      await storage.putString('push.notification_prompted', 'true');
      final gate = NotificationPermissionGate(seam: seam, storage: storage);
      await gate.requestIfFirstTime();
      expect(seam.requestCalls, 1);
    });
  });

  group('NotificationPermissionSeamStub', () {
    test('returns false (treat as denied) so callers see a uniform "no" path',
        () async {
      expect(await NotificationPermissionSeamStub().request(), isFalse);
    });
  });
}
