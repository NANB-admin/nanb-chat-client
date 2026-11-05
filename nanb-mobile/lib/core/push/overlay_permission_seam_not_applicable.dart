import 'overlay_permission_gate.dart';

/// For platforms with no "display over other apps" concept (the browser).
/// Reporting it as already granted makes `OverlayPermissionGate.needsPrompt`
/// false, so the rationale dialog is never shown.
class OverlayPermissionSeamNotApplicable implements OverlayPermissionSeam {
  @override
  Future<bool> isGranted() async => true;

  @override
  Future<void> openSettings() async {}
}
