import 'package:flutter_test/flutter_test.dart';
import 'package:nanb_chat/features/chat/media_pipeline.dart';
import 'package:nanb_chat/features/chat/models/chat_message.dart';
import 'package:nanb_chat/features/chat/models/client_msg_id_header.dart';
import 'package:nanb_chat/features/chat/models/forward_marker.dart';
import 'package:nanb_chat/features/chat/models/message_kind.dart';
import 'package:nanb_chat/features/chat/models/reply_ref.dart';
import 'package:nanb_chat/features/chat/models/ttl_header.dart';
import 'package:nanb_chat/features/chat/services/resend_wire_body.dart';

final _now = DateTime.utc(2026, 11, 6, 12);

ChatMessage _message({
  String? clientMsgId = 'cid-1',
  String body = 'hello',
  MessageKind kind = MessageKind.text,
  DateTime? expiresAt,
  bool forwarded = false,
  String? replyToEnvelopeId,
  String? mediaId,
}) =>
    ChatMessage(
      envelopeId: 'env-1',
      conversationId: '1to1:a:b',
      senderDeviceId: 'dev-me',
      body: body,
      serverTs: _now.subtract(const Duration(hours: 1)),
      mine: true,
      clientMsgId: clientMsgId,
      kind: kind,
      expiresAt: expiresAt,
      forwarded: forwarded,
      replyToEnvelopeId: replyToEnvelopeId,
      replyToSender: replyToEnvelopeId == null ? null : 'bob',
      replyToPreview: replyToEnvelopeId == null ? null : 'earlier',
      mediaId: mediaId,
      mediaKey: mediaId == null ? null : const [1, 2],
      mediaSha256: mediaId == null ? null : const [3, 4],
      mediaSize: mediaId == null ? null : 10,
      mediaMime: mediaId == null ? null : 'image/png',
    );

void main() {
  group('buildResendWireBody', () {
    test('carries the original client message id as the outermost header', () {
      final wire = buildResendWireBody(_message(), now: _now)!;

      expect(ClientMsgIdHeader.split(wire)!.$1.id, 'cid-1');
    });

    test('carries the text after the header', () {
      final wire = buildResendWireBody(_message(), now: _now)!;

      expect(ClientMsgIdHeader.split(wire)!.$2, 'hello');
    });

    test('returns null without a client message id', () {
      // The receiver could not dedup it, so a resend might render twice.
      expect(buildResendWireBody(_message(clientMsgId: null), now: _now), isNull);
    });

    test('returns null for a system message', () {
      expect(buildResendWireBody(_message(kind: MessageKind.system), now: _now),
          isNull);
    });

    test('returns null for an already expired message', () {
      final m = _message(expiresAt: _now.subtract(const Duration(seconds: 1)));

      expect(buildResendWireBody(m, now: _now), isNull);
    });

    test('a disappearing message keeps only its remaining lifetime', () {
      final m = _message(expiresAt: _now.add(const Duration(seconds: 90)));

      final afterCid =
          ClientMsgIdHeader.split(buildResendWireBody(m, now: _now)!)!.$2;

      expect(TtlHeader.split(afterCid)!.$1.ttlSeconds, 90);
    });

    test('keeps the forward marker', () {
      final wire = buildResendWireBody(_message(forwarded: true), now: _now)!;

      expect(ClientMsgIdHeader.split(wire)!.$2,
          startsWith(ForwardMarker.prefix));
    });

    test('keeps the reply reference', () {
      final wire =
          buildResendWireBody(_message(replyToEnvelopeId: 'env-0'), now: _now)!;

      final reply = ReplyRef.split(ClientMsgIdHeader.split(wire)!.$2)!;

      expect(reply.$1.envelopeId, 'env-0');
    });

    test('rebuilds a media descriptor from the stored fields', () {
      final m = _message(kind: MessageKind.image, body: '', mediaId: 'media-1');

      final afterCid =
          ClientMsgIdHeader.split(buildResendWireBody(m, now: _now)!)!.$2;

      expect(MediaDescriptor.fromJson(afterCid).mediaId, 'media-1');
    });

    test('keeps a media caption on the line after the descriptor', () {
      final m =
          _message(kind: MessageKind.image, body: 'look', mediaId: 'media-1');

      final afterCid =
          ClientMsgIdHeader.split(buildResendWireBody(m, now: _now)!)!.$2;

      expect(afterCid.split('\n').last, 'look');
    });

    test('returns null for media without its stored descriptor fields', () {
      final m = _message(kind: MessageKind.image, body: '');

      expect(buildResendWireBody(m, now: _now), isNull);
    });
  });
}
