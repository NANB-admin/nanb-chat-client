import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/models/history_backfill.dart';
import 'package:nanb_chat/features/chat/models/message_control.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';

void main() {
  group('HistoryBackfill', () {
    test('encode/decode round-trips a text + media message batch', () {
      final payload = HistoryBackfill(
        conversationId: '1to1:a:b',
        seq: 2,
        total: 3,
        messages: const [
          BackfillMessage(
            envelopeId: 'env-1',
            serverTsMs: 1718200000000,
            senderDeviceId: 'dev-1',
            mine: true,
            kind: MessageKind.text,
            body: 'hello',
          ),
          BackfillMessage(
            envelopeId: 'env-2',
            serverTsMs: 1718200001000,
            senderDeviceId: 'peer-dev',
            mine: false,
            kind: MessageKind.image,
            body: 'caption',
            mediaId: 'm-9',
            mediaKey: [1, 2, 3, 4],
            mediaSha256: [9, 9],
            mediaSize: 4096,
            mediaMime: 'image/jpeg',
            expiresAtMs: 1718900000000,
            replyToEnvelopeId: 'env-0',
            replyToSender: '@alice',
            replyToPreview: 'prev',
            forwarded: true,
          ),
        ],
      );

      final decoded = HistoryBackfill.tryDecode(payload.encode())!;
      expect(decoded.conversationId, '1to1:a:b');
      expect(decoded.seq, 2);
      expect(decoded.total, 3);
      expect(decoded.messages.length, 2);

      final a = decoded.messages[0];
      expect(a.envelopeId, 'env-1');
      expect(a.serverTsMs, 1718200000000);
      expect(a.mine, isTrue);
      expect(a.kind, MessageKind.text);
      expect(a.body, 'hello');

      final b = decoded.messages[1];
      expect(b.envelopeId, 'env-2');
      expect(b.mine, isFalse);
      expect(b.kind, MessageKind.image);
      expect(b.body, 'caption');
      expect(b.mediaId, 'm-9');
      expect(b.mediaKey, [1, 2, 3, 4]);
      expect(b.mediaSha256, [9, 9]);
      expect(b.mediaSize, 4096);
      expect(b.mediaMime, 'image/jpeg');
      expect(b.expiresAtMs, 1718900000000);
      expect(b.replyToEnvelopeId, 'env-0');
      expect(b.replyToSender, '@alice');
      expect(b.replyToPreview, 'prev');
      expect(b.forwarded, isTrue);
    });

    test('tryDecode rejects non-backfill bodies', () {
      expect(HistoryBackfill.tryDecode('hello'), isNull);
      expect(HistoryBackfill.tryDecode('{"_control":"receipt","kind":"read","ids":["x"]}'),
          isNull);
      expect(HistoryBackfill.tryDecode('{}'), isNull);
      expect(HistoryBackfill.tryDecode(''), isNull);
      expect(HistoryBackfill.tryDecode('not json'), isNull);
    });

    test('MessageControl and HistoryBackfill never collide on the same body', () {
      final backfillBody = const HistoryBackfill(
        conversationId: 'c',
        seq: 1,
        total: 1,
        messages: [],
      ).encode();
      // A backfill body must NOT be mis-parsed as a MessageControl, and a
      // control body must NOT be mis-parsed as backfill.
      expect(MessageControl.tryDecode(backfillBody), isNull);
      final controlBody = const MessageControl.reestablish().encode();
      expect(HistoryBackfill.tryDecode(controlBody), isNull);
    });
  });
}
