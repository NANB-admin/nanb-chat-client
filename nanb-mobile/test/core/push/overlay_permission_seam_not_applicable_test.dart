import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/push/overlay_permission_gate.dart';
import 'package:nanb_chat/core/push/overlay_permission_seam_not_applicable.dart';
import 'package:nanb_chat/core/secure_storage/secure_storage.dart';

void main() {
  test('reports the permission as granted', () async {
    expect(await OverlayPermissionSeamNotApplicable().isGranted(), isTrue);
  });

  test('openSettings completes without doing anything', () async {
    await expectLater(OverlayPermissionSeamNotApplicable().openSettings(), completes);
  });

  test('the gate never asks to show the rationale with this seam', () async {
    final gate = OverlayPermissionGate(
      seam: OverlayPermissionSeamNotApplicable(),
      storage: SecureStorageInMemory(),
    );

    expect(await gate.needsPrompt(), isFalse);
  });
}
