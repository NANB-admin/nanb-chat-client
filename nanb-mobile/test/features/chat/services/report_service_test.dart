import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nanb_chat/core/db/app_database.dart';
import 'package:nanb_chat/core/models/report_reason.dart';
import 'package:nanb_chat/core/models/report_request.dart';
import 'package:nanb_chat/core/network/api_client.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/conversation.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/services/report_service.dart';

class _MockApi extends Mock implements ApiClient {}

class _MockDb extends Mock implements AppDatabase {}

ChatMessage _msg({
  required String id,
  required bool mine,
  String body = 'hi',
  MessageKind kind = MessageKind.text,
  int tsMs = 0,
}) =>
    ChatMessage(
      envelopeId: id,
      conversationId: 'c1',
      senderDeviceId: mine ? 'me' : 'them',
      body: body,
      serverTs: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
      mine: mine,
      kind: kind,
    );

Conversation _convo() => const Conversation(
      id: 'c1',
      peerUsername: 'alice',
      peerAccountId: 'acc-alice',
      peerDeviceId: 'dev-alice',
      peerIdentityPubKey: [],
      messages: [],
      unreadCount: 0,
    );

void main() {
  late _MockApi api;
  late _MockDb db;
  late ReportService service;

  setUpAll(() {
    registerFallbackValue(
      const ReportRequest(
        reportedAccountId: 'x',
        reportedUsername: 'x',
        reason: ReportReason.other,
      ),
    );
  });

  setUp(() {
    api = _MockApi();
    db = _MockDb();
    service = ReportService(api: api, db: db);
    when(() => api.reportUser(any())).thenAnswer((_) async {});
  });

  ReportRequest captured() =>
      verify(() => api.reportUser(captureAny())).captured.single
          as ReportRequest;

  test("attaches only the peer's non-system messages as evidence", () async {
    when(() => db.loadMessages('c1', limit: any(named: 'limit'))).thenAnswer(
      (_) async => [
        _msg(id: 'm1', mine: true, body: 'my reply'),
        _msg(id: 'm2', mine: false, body: 'abuse 1'),
        _msg(id: 'm3', mine: false, body: '', kind: MessageKind.system),
        _msg(id: 'm4', mine: false, body: 'abuse 2'),
      ],
    );

    await service.reportConversation(
        convo: _convo(), reason: ReportReason.harassment);

    final req = captured();
    expect(req.messages.map((m) => m.body), ['abuse 1', 'abuse 2']);
    expect(req.messages.every((m) => m.sender == 'alice'), isTrue);
  });

  test('caps evidence to the most-recent evidenceMessageCount messages',
      () async {
    when(() => db.loadMessages('c1', limit: any(named: 'limit'))).thenAnswer(
      (_) async => [
        for (var i = 0; i < 15; i++)
          _msg(id: 'm$i', mine: false, body: 'b$i', tsMs: i),
      ],
    );

    await service.reportConversation(
        convo: _convo(), reason: ReportReason.spam);

    final req = captured();
    expect(req.messages.length, ReportService.evidenceMessageCount);
    expect(req.messages.first.body, 'b5');
    expect(req.messages.last.body, 'b14');
  });

  test('labels media evidence with its kind when there is no caption',
      () async {
    when(() => db.loadMessages('c1', limit: any(named: 'limit'))).thenAnswer(
      (_) async =>
          [_msg(id: 'm1', mine: false, body: '', kind: MessageKind.image)],
    );

    await service.reportConversation(
        convo: _convo(), reason: ReportReason.other);

    expect(captured().messages.single.body, '[image]');
  });

  test('sets reported identity, reason, note, and conversation from the convo',
      () async {
    when(() => db.loadMessages('c1', limit: any(named: 'limit')))
        .thenAnswer((_) async => []);

    await service.reportConversation(
      convo: _convo(),
      reason: ReportReason.impersonation,
      note: 'pretending to be my bank',
    );

    final req = captured();
    expect(req.reportedAccountId, 'acc-alice');
    expect(req.reportedUsername, 'alice');
    expect(req.conversationId, 'c1');
    expect(req.reason, ReportReason.impersonation);
    expect(req.note, 'pretending to be my bank');
  });
}
