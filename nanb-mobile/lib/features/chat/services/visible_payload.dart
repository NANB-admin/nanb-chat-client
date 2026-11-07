import '../../calls/models/call_signal.dart';
import '../models/client_msg_id_header.dart';
import '../models/forward_marker.dart';
import '../models/history_backfill.dart';
import '../models/message_control.dart';
import '../models/privacy_header.dart';
import '../models/reply_ref.dart';
import '../models/system_event.dart';
import '../models/ttl_header.dart';

/// Whether a decrypted body is a message the user would see, rather than one
/// of the payloads that only steer the app (receipts, read position, calls,
/// history, group info). Strips the prefix headers the same way
/// `MessageAppender` does before it routes a body.
class VisiblePayload {
  const VisiblePayload._();

  static bool isVisible(String raw) {
    var body = ClientMsgIdHeader.split(raw)?.$2 ?? raw;
    body = TtlHeader.split(body)?.$2 ?? body;
    body = PrivacyHeader.split(body)?.$2 ?? body;
    body = ReplyRef.split(body)?.$2 ?? body;
    body = ForwardMarker.split(body) ?? body;
    return MessageControl.tryDecode(body) == null &&
        CallSignal.tryDecode(body) == null &&
        HistoryBackfill.tryDecode(body) == null &&
        SystemEvent.tryDecode(body) == null;
  }
}
