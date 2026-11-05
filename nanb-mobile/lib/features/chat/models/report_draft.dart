import '../../../core/models/report_reason.dart';

/// The user's in-progress report selection, returned by the report sheet to the
/// screen that then submits it. UI-local: just the choices a person makes in the
/// sheet (reason, optional note, whether to also block).
class ReportDraft {
  const ReportDraft({
    required this.reason,
    this.note,
    this.alsoBlock = true,
  });

  final ReportReason reason;
  final String? note;
  final bool alsoBlock;
}
