import '../../../core/db/app_database.dart';
import '../../../core/models/report_reason.dart';
import '../../../core/models/report_request.dart';
import '../../../core/models/reported_message.dart';
import '../../../core/network/api_client.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/message_kind.dart';

/// Builds and submits a user-abuse report. The report attaches the reported
/// user's most recent messages as evidence (the reporter's OWN messages and
/// in-thread system pills are never included), then posts it to the server
/// moderation queue. Single-purpose: it does not block — the caller decides.
class ReportService {
  ReportService({required ApiClient api, required AppDatabase db})
      : _api = api,
        _db = db;

  final ApiClient _api;
  final AppDatabase _db;

  /// How many of the peer's recent messages to forward as evidence.
  static const int evidenceMessageCount = 10;

  /// How many recent messages to scan to find that evidence (covers a chat
  /// where the reporter's own replies are interleaved with the peer's).
  static const int _scanWindow = 40;

  Future<void> reportConversation({
    required Conversation convo,
    required ReportReason reason,
    String? note,
  }) async {
    final recent = await _db.loadMessages(convo.id, limit: _scanWindow);
    final evidence = <ReportedMessage>[];
    for (final m in recent) {
      if (m.mine || m.kind == MessageKind.system) continue;
      evidence.add(ReportedMessage(
        sender: convo.peerUsername,
        body: _evidenceBody(m),
        kind: m.kind.name,
        sentAt: m.serverTs,
      ));
    }
    // Keep only the most recent few (loadMessages returns ascending order).
    final tail = evidence.length > evidenceMessageCount
        ? evidence.sublist(evidence.length - evidenceMessageCount)
        : evidence;

    await _api.reportUser(ReportRequest(
      reportedAccountId: convo.peerAccountId,
      reportedUsername: convo.peerUsername,
      conversationId: convo.id,
      reason: reason,
      note: note,
      messages: tail,
    ));
  }

  /// For text, the message itself; for media the body is just an optional
  /// caption, so prefix a `[kind]` label so a reviewer knows what was sent even
  /// when there is no caption.
  String _evidenceBody(ChatMessage m) {
    if (m.kind == MessageKind.text) return m.body;
    final label = '[${m.kind.name}]';
    return m.body.isEmpty ? label : '$label ${m.body}';
  }
}
