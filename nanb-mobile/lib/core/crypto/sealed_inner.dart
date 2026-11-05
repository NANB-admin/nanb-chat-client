import 'dart:convert';
import 'dart:typed_data';

/// The inner record carried *inside* a `SealedEnvelope` (sealed-sender Phase 1,
/// see `docs/sealed-sender-design.md`).
///
/// It holds exactly what the server used to see in the clear and what the
/// recipient needs to process the message as a normal envelope: the
/// conversation, the envelope type, the (self-asserted) sender, and the real
/// E2EE ciphertext. The recipient opens the outer layer, decodes this, and
/// dispatches it through the existing receive path using the OUTER envelope's id
/// + recipient fields + server timestamp (those stay outside, since the server
/// needs them to route and the recipient to ack).
///
/// Compact length-prefixed binary — UTF-8 strings, big-endian lengths — to keep
/// the per-recipient sealed copies small (a send fans out one blob per device):
/// ```
///   version(1) | convLen(2) conv | typeLen(1) type | sndLen(2) snd | ciphertext…
/// ```
class SealedInner {
  const SealedInner({
    required this.conversationId,
    required this.envelopeType,
    required this.senderDeviceId,
    required this.ciphertext,
  });

  final String conversationId;
  final String envelopeType;
  final String senderDeviceId;
  final List<int> ciphertext;

  static const int version = 0x01;

  Uint8List encode() {
    final conv = utf8.encode(conversationId);
    final type = utf8.encode(envelopeType);
    final snd = utf8.encode(senderDeviceId);
    if (conv.length > 0xFFFF) throw ArgumentError('conversationId too long');
    if (type.length > 0xFF) throw ArgumentError('envelopeType too long');
    if (snd.length > 0xFFFF) throw ArgumentError('senderDeviceId too long');
    return (BytesBuilder(copy: false)
          ..addByte(version)
          ..addByte((conv.length >> 8) & 0xFF)
          ..addByte(conv.length & 0xFF)
          ..add(conv)
          ..addByte(type.length & 0xFF)
          ..add(type)
          ..addByte((snd.length >> 8) & 0xFF)
          ..addByte(snd.length & 0xFF)
          ..add(snd)
          ..add(ciphertext))
        .toBytes();
  }

  static SealedInner decode(List<int> bytes) {
    if (bytes.isEmpty || bytes[0] != version) {
      throw const FormatException('unsupported sealed-inner version');
    }
    var off = 1;
    int u8() {
      if (off + 1 > bytes.length) throw const FormatException('truncated');
      return bytes[off++];
    }
    int u16() {
      if (off + 2 > bytes.length) throw const FormatException('truncated');
      final v = (bytes[off] << 8) | bytes[off + 1];
      off += 2;
      return v;
    }
    List<int> take(int n) {
      if (off + n > bytes.length) throw const FormatException('truncated');
      final s = bytes.sublist(off, off + n);
      off += n;
      return s;
    }

    final conv = utf8.decode(take(u16()));
    final type = utf8.decode(take(u8()));
    final snd = utf8.decode(take(u16()));
    final ct = bytes.sublist(off); // remainder
    return SealedInner(
      conversationId: conv,
      envelopeType: type,
      senderDeviceId: snd,
      ciphertext: ct,
    );
  }
}
