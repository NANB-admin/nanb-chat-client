import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/core/models/report_reason.dart';
import 'package:nanb_chat/core/models/report_request.dart';
import 'package:nanb_chat/core/models/reported_message.dart';

void main() {
  test('serializes the reason as its wire value', () {
    final json = const ReportRequest(
      reportedAccountId: 'acc',
      reportedUsername: 'bob',
      reason: ReportReason.childSafety,
    ).toJson();

    expect(json['reason'], 'child_safety');
    expect(json['reported_account_id'], 'acc');
    expect(json['reported_username'], 'bob');
  });

  test('omits a blank note and empty messages', () {
    final json = const ReportRequest(
      reportedAccountId: 'acc',
      reportedUsername: 'bob',
      reason: ReportReason.spam,
      note: '   ',
    ).toJson();

    expect(json.containsKey('note'), isFalse);
    expect(json.containsKey('messages'), isFalse);
  });

  test('serializes evidence messages when present', () {
    final json = ReportRequest(
      reportedAccountId: 'acc',
      reportedUsername: 'bob',
      reason: ReportReason.spam,
      messages: [
        ReportedMessage(
          sender: 'bob',
          body: 'buy now',
          kind: 'text',
          sentAt: DateTime.utc(2026, 6, 27, 12),
        ),
      ],
    ).toJson();

    final msgs = json['messages'] as List;
    expect(msgs, hasLength(1));
    final m = msgs.single as Map<String, dynamic>;
    expect(m['body'], 'buy now');
    expect(m['sent_at'], '2026-06-27T12:00:00.000Z');
  });
}
