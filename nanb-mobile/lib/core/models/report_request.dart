import 'report_reason.dart';
import 'reported_message.dart';

/// Body of `POST /reports`. The reporter is taken from the authenticated JWT on
/// the server, never from this payload — this carries only who is being
/// reported, why, and any forwarded evidence.
class ReportRequest {
  const ReportRequest({
    required this.reportedAccountId,
    required this.reportedUsername,
    required this.reason,
    this.conversationId,
    this.note,
    this.messages = const [],
  });

  final String reportedAccountId;
  final String reportedUsername;
  final ReportReason reason;
  final String? conversationId;
  final String? note;
  final List<ReportedMessage> messages;

  Map<String, dynamic> toJson() => {
        'reported_account_id': reportedAccountId,
        'reported_username': reportedUsername,
        'reason': reason.wire,
        if (conversationId != null && conversationId!.isNotEmpty)
          'conversation_id': conversationId,
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
        if (messages.isNotEmpty)
          'messages': messages.map((m) => m.toJson()).toList(growable: false),
      };
}
