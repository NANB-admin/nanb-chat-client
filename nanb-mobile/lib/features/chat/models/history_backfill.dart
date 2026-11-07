import 'dart:convert';

import 'message_kind.dart';

/// One past message replayed to a freshly-linked own device as history
/// backfill. Mirrors the displayable subset of `ChatMessage`: the receiver
/// reconstructs a ChatMessage straight from these fields (no wire-header
/// re-parsing), so the ORIGINAL envelope id / timestamp / `mine` attribution
/// are preserved — that is what lets the row dedup against any live copy and
/// sort into its real position rather than landing at "now".
class BackfillMessage {
  const BackfillMessage({
    required this.envelopeId,
    required this.serverTsMs,
    required this.senderDeviceId,
    required this.mine,
    required this.kind,
    required this.body,
    this.expiresAtMs,
    this.mediaId,
    this.mediaKey,
    this.mediaSha256,
    this.mediaSize,
    this.mediaMime,
    this.mediaFilename,
    this.voiceWaveform,
    this.mediaDurationMs,
    this.replyToEnvelopeId,
    this.replyToSender,
    this.replyToPreview,
    this.forwarded = false,
    this.clientMsgId,
  });

  final String envelopeId;
  final int serverTsMs;
  final String senderDeviceId;
  final bool mine;
  final MessageKind kind;
  final String body;
  final int? expiresAtMs;
  final String? mediaId;
  final List<int>? mediaKey;
  final List<int>? mediaSha256;
  final int? mediaSize;
  final String? mediaMime;
  final String? mediaFilename;
  final List<int>? voiceWaveform;
  final int? mediaDurationMs;
  final String? replyToEnvelopeId;
  final String? replyToSender;
  final String? replyToPreview;
  final bool forwarded;

  /// The sender's own id for this message, the same on every device. Envelope
  /// ids differ per device, so this is what tells a device it already has a
  /// message its sibling replays.
  final String? clientMsgId;

  /// Compact JSON. Byte arrays are base64 (smaller + safe inside JSON); absent
  /// optional fields are omitted to keep chunks small.
  Map<String, Object?> toJson() => {
        'eid': envelopeId,
        'ts': serverTsMs,
        'sdev': senderDeviceId,
        'mine': mine,
        'kind': kind.name,
        'body': body,
        if (expiresAtMs != null) 'exp': expiresAtMs,
        if (mediaId != null) 'mid': mediaId,
        if (mediaKey != null) 'mkey': base64.encode(mediaKey!),
        if (mediaSha256 != null) 'msha': base64.encode(mediaSha256!),
        if (mediaSize != null) 'msz': mediaSize,
        if (mediaMime != null) 'mmime': mediaMime,
        if (mediaFilename != null) 'mfn': mediaFilename,
        if (voiceWaveform != null) 'wav': base64.encode(voiceWaveform!),
        if (mediaDurationMs != null) 'dur': mediaDurationMs,
        if (replyToEnvelopeId != null) 'reid': replyToEnvelopeId,
        if (replyToSender != null) 'rsnd': replyToSender,
        if (replyToPreview != null) 'rprev': replyToPreview,
        if (forwarded) 'fwd': true,
        if (clientMsgId != null) 'cid': clientMsgId,
      };

  static BackfillMessage? fromJson(Map<Object?, Object?> j) {
    final eid = j['eid'];
    final ts = j['ts'];
    final sdev = j['sdev'];
    final body = j['body'];
    if (eid is! String ||
        eid.isEmpty ||
        ts is! int ||
        sdev is! String ||
        body is! String) {
      return null;
    }
    var kind = MessageKind.text;
    final kindStr = j['kind'];
    if (kindStr is String) {
      for (final k in MessageKind.values) {
        if (k.name == kindStr) kind = k;
      }
    }
    List<int>? bytes(Object? v) {
      if (v is! String) return null;
      try {
        return base64.decode(v);
      } catch (_) {
        return null;
      }
    }

    return BackfillMessage(
      envelopeId: eid,
      serverTsMs: ts,
      senderDeviceId: sdev,
      mine: j['mine'] == true,
      kind: kind,
      body: body,
      expiresAtMs: j['exp'] is int ? j['exp'] as int : null,
      mediaId: j['mid'] is String ? j['mid'] as String : null,
      mediaKey: bytes(j['mkey']),
      mediaSha256: bytes(j['msha']),
      mediaSize: j['msz'] is int ? j['msz'] as int : null,
      mediaMime: j['mmime'] is String ? j['mmime'] as String : null,
      mediaFilename: j['mfn'] is String ? j['mfn'] as String : null,
      voiceWaveform: bytes(j['wav']),
      mediaDurationMs: j['dur'] is int ? j['dur'] as int : null,
      replyToEnvelopeId: j['reid'] is String ? j['reid'] as String : null,
      replyToSender: j['rsnd'] is String ? j['rsnd'] as String : null,
      replyToPreview: j['rprev'] is String ? j['rprev'] as String : null,
      forwarded: j['fwd'] == true,
      clientMsgId: j['cid'] is String ? j['cid'] as String : null,
    );
  }
}

/// A chunk of one conversation's history replayed to a freshly-linked own
/// device. Rides inside the encrypted MLS body (own-device only) like the
/// other [MessageControl]-style payloads, but carries a LIST of messages, so
/// it has its own type. The receiver honours the embedded original metadata
/// and stores each message idempotently (dedup on envelope id) without bumping
/// unread or firing receipts. [seq]/[total] are for progress/debugging only —
/// chunks are independent and each is useful on its own.
class HistoryBackfill {
  const HistoryBackfill({
    required this.conversationId,
    required this.seq,
    required this.total,
    required this.messages,
  });

  final String conversationId;
  final int seq;
  final int total;
  final List<BackfillMessage> messages;

  String encode() => jsonEncode({
        '_control': 'history_backfill',
        'convo': conversationId,
        'seq': seq,
        'total': total,
        'msgs': [for (final m in messages) m.toJson()],
      });

  /// Returns the backfill payload if [body] is one, else null. Fast-rejects
  /// non-JSON so normal text never pays the parse. Distinct `_control` value
  /// from [MessageControl], so the two decoders never collide.
  static HistoryBackfill? tryDecode(String body) {
    if (body.isEmpty || body.codeUnitAt(0) != 0x7B /* '{' */) return null;
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (raw is! Map || raw['_control'] != 'history_backfill') return null;
    final convo = raw['convo'];
    final msgs = raw['msgs'];
    if (convo is! String || convo.isEmpty || msgs is! List) return null;
    final parsed = <BackfillMessage>[];
    for (final m in msgs) {
      if (m is Map) {
        final bm = BackfillMessage.fromJson(m.cast<Object?, Object?>());
        if (bm != null) parsed.add(bm);
      }
    }
    return HistoryBackfill(
      conversationId: convo,
      seq: raw['seq'] is int ? raw['seq'] as int : 0,
      total: raw['total'] is int ? raw['total'] as int : 1,
      messages: parsed,
    );
  }
}
