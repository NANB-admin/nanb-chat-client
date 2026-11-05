import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/overlay_permission_gate.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

class _FakeSeam implements OverlayPermissionSeam {
  _FakeSeam({this.granted = false});

  bool granted;
  int openSettingsCalls = 0;

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<void> openSettings() async => openSettingsCalls++;
}

void main() {
  group('OverlayPermissionGate.needsPrompt', () {
    test('true when never prompted and not granted', () async {
      final gate = OverlayPermissionGate(
        seam: _FakeSeam(granted: false),
        storage: SecureStorageInMemory(),
      );
      expect(await gate.needsPrompt(), isTrue);
    });

    test('false when already granted (and does not persist a flag)', () async {
      final storage = SecureStorageInMemory();
      final gate = OverlayPermissionGate(
        seam: _FakeSeam(granted: true),
        storage: storage,
      );
      expect(await gate.needsPrompt(), isFalse);
      // Intentionally NOT marked, so a later revoke re-surfaces the rationale.
      expect(await storage.getString(OverlayPermissionGate.storageKey), isNull);
    });

    test('false once marked, even if still not granted', () async {
      final storage = SecureStorageInMemory();
      final gate = OverlayPermissionGate(
        seam: _FakeSeam(granted: false),
        storage: storage,
      );
      expect(await gate.needsPrompt(), isTrue);
      await gate.markPrompted();
      expect(await gate.needsPrompt(), isFalse);
    });
  });

  group('OverlayPermissionGate.markPrompted', () {
    test('persists the prompted flag', () async {
      final storage = SecureStorageInMemory();
      final gate = OverlayPermissionGate(
        seam: _FakeSeam(),
        storage: storage,
      );
      await gate.markPrompted();
      expect(
        await storage.getString(OverlayPermissionGate.storageKey),
        'true',
      );
    });
  });

  group('OverlayPermissionGate.openSettings', () {
    test('delegates to the seam', () async {
      final seam = _FakeSeam();
      final gate = OverlayPermissionGate(
        seam: seam,
        storage: SecureStorageInMemory(),
      );
      await gate.openSettings();
      expect(seam.openSettingsCalls, 1);
    });
  });
}
