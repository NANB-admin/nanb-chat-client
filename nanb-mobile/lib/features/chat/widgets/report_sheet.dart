import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../core/models/report_reason.dart';
import '../models/report_draft.dart';

/// Human-facing label for a report reason. Lives here (presentation) rather than
/// on [ReportReason], which stays a pure data type.
String reportReasonLabel(ReportReason r) {
  switch (r) {
    case ReportReason.spam:
      return 'Spam';
    case ReportReason.harassment:
      return 'Harassment or bullying';
    case ReportReason.threats:
      return 'Violence or threats';
    case ReportReason.sexualContent:
      return 'Unwanted sexual content';
    case ReportReason.childSafety:
      return 'Child safety';
    case ReportReason.impersonation:
      return 'Impersonation';
    case ReportReason.other:
      return 'Other';
  }
}

/// Bottom sheet to report [peerUsername]. Returns the chosen [ReportDraft] on
/// submit, or null if dismissed/cancelled.
///
/// [showBlockOption] false hides the "Also block" switch for flows that already
/// end the conversation themselves (rejecting a message request); the returned
/// draft then has `alsoBlock: true`. [submitLabel] renames the confirm button.
Future<ReportDraft?> showReportSheet(
  BuildContext context, {
  required String peerUsername,
  bool showBlockOption = true,
  String submitLabel = 'Report',
}) {
  return showModalBottomSheet<ReportDraft>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _ReportSheet(
      peerUsername: peerUsername,
      showBlockOption: showBlockOption,
      submitLabel: submitLabel,
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.peerUsername,
    required this.showBlockOption,
    required this.submitLabel,
  });
  final String peerUsername;
  final bool showBlockOption;
  final String submitLabel;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  bool _alsoBlock = true;
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason;
    if (reason == null) return;
    Navigator.of(context).pop(ReportDraft(
      reason: reason,
      note: _note.text,
      alsoBlock: _alsoBlock,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    // Lift the sheet above the keyboard when the note field is focused.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border(top: BorderSide(color: t.border)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Report ${widget.peerUsername}',
                    style: TextStyle(
                      fontSize: 15,
                      color: t.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Choose a reason. Your most recent messages from '
                    '${widget.peerUsername} will be sent to NANb for review.',
                    style:
                        TextStyle(fontSize: 12, color: t.textMuted, height: 1.4),
                  ),
                ),
                const Divider(height: 1),
                Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      for (final r in ReportReason.values)
                        ListTile(
                          key: ValueKey('report-reason-${r.wire}'),
                          dense: true,
                          title: Text(
                            reportReasonLabel(r),
                            style: TextStyle(fontSize: 14, color: t.text),
                          ),
                          trailing: _reason == r
                              ? Icon(Icons.check, size: 18, color: t.accent)
                              : null,
                          onTap: () => setState(() => _reason = r),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _note,
                    maxLines: 3,
                    maxLength: 2000,
                    style: TextStyle(fontSize: 14, color: t.text),
                    decoration: InputDecoration(
                      hintText: 'Add details (optional)',
                      hintStyle: TextStyle(color: t.textFaint),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.accent),
                      ),
                    ),
                  ),
                ),
                if (widget.showBlockOption)
                  SwitchListTile(
                    key: const ValueKey('report-also-block'),
                    value: _alsoBlock,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      'Also block ${widget.peerUsername}',
                      style: TextStyle(fontSize: 14, color: t.text),
                    ),
                    onChanged: (v) => setState(() => _alsoBlock = v),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const ValueKey('report-submit'),
                          onPressed: _reason == null ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: t.danger,
                            foregroundColor: Colors.white,
                          ),
                          child: Text(widget.submitLabel),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
