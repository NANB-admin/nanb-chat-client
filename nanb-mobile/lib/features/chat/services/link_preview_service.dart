import 'dart:async';

import '../models/chat_message.dart';
import '../models/link_preview.dart';
import '../models/message_control.dart';
import '../models/message_kind.dart';
import 'link_detector.dart';
import 'notifier_service_host.dart';

/// Builds one link's preview card, or null when there isn't one. The app backs
/// this with the Tor-routed fetcher; null from the supplier means previews are
/// currently off / have no safe route.
typedef LinkPreviewSource = Future<LinkPreview?> Function(String url);

/// Owns link previews: after one of OUR messages containing a link is sent, fetch
/// the card on this device and share it with the conversation as a
/// `link_preview` control, and apply such controls from others.
///
/// The fetch happens only on the author's device, so the recipient never contacts
/// the linked site. Sending the message never waits on this: the card appears a
/// moment later, or not at all if the fetch fails.
class LinkPreviewService {
  LinkPreviewService(this._host, {required LinkPreviewSource? Function() source})
      : _source = source;

  final NotifierServiceHost _host;
  final LinkPreviewSource? Function() _source;

  /// Call (post-lock) once [sent] — one of our own messages — has been acked.
  /// No-op for anything that isn't our text message with a link.
  Future<void> attachFor(ChatMessage sent) async {
    if (!sent.mine || sent.kind != MessageKind.text) return;
    final links = LinkDetector.find(sent.body);
    if (links.isEmpty) return;
    final source = _source();
    if (source == null) return;

    final LinkPreview? preview;
    try {
      preview = await source(links.first.url);
    } catch (_) {
      return; // best effort — a failed fetch just means no card
    }
    if (preview == null) return;

    final conversationId = sent.conversationId;
    await _host.runLocked(
      conversationId,
      () => _applyLocked(conversationId, sent.envelopeId, preview!),
    );
    final control = MessageControl.linkPreview(
      targetEnvelopeId: sent.envelopeId,
      preview: preview,
    ).encode();
    // Peer (relayed to the peer's devices) + our own other devices.
    unawaited(_host.sendControl(conversationId, control));
    unawaited(_host.sendSelfControl(conversationId, control));
  }

  /// Applies an inbound link-preview [control]. The CALLER MUST HOLD the
  /// conversation lock (this runs on the already-locked decrypt path).
  ///
  /// A preview is accepted only from the message's author and only for a link the
  /// message actually contains — otherwise a participant could pin a fake card
  /// (a trusted-looking title over a different destination) onto someone else's
  /// message.
  Future<void> applyInbound({
    required String conversationId,
    required MessageControl control,
    required String senderDeviceId,
    required String myDeviceId,
  }) async {
    final preview = control.linkPreview;
    if (preview == null) return;
    final target = await _find(conversationId, control.targetEnvelopeId);
    if (target == null || target.kind != MessageKind.text) return;

    final senderIsMe = await _host.isMyDeviceWarm(senderDeviceId, myDeviceId);
    if (senderIsMe != target.mine) return; // not the author's side
    if (!senderIsMe && target.senderDeviceId != senderDeviceId) return;

    final linksInBody = LinkDetector.find(target.body).map((l) => l.url);
    if (!linksInBody.contains(preview.url)) return;

    await _applyLocked(conversationId, target.envelopeId, preview);
  }

  Future<ChatMessage?> _find(String conversationId, String envelopeId) async {
    final live = _host.conversation(conversationId);
    if (live != null) {
      for (final m in live.messages) {
        if (m.envelopeId == envelopeId) return m;
      }
    }
    return _host.db.getMessage(envelopeId);
  }

  /// Stores [preview] on the message and notifies. The caller must hold the
  /// conversation lock.
  Future<void> _applyLocked(
    String conversationId,
    String envelopeId,
    LinkPreview preview,
  ) async {
    final live = _host.conversation(conversationId);
    final idx = live?.messages.indexWhere((m) => m.envelopeId == envelopeId) ?? -1;
    if (live == null || idx < 0) {
      // Not in the loaded window — update the stored row so the card shows when
      // it is next loaded. Nothing visible changes, so no notify.
      final stored = await _host.db.getMessage(envelopeId);
      if (stored == null || stored.linkPreview == preview) return;
      await _host.db
          .upsertMessages(conversationId, [stored.copyWith(linkPreview: preview)]);
      return;
    }
    final current = live.messages[idx];
    if (current.linkPreview == preview) return;
    final updated = current.copyWith(linkPreview: preview);
    final messages = [...live.messages]..[idx] = updated;
    _host.setConversation(conversationId, live.copyWith(messages: messages));
    await _host.db.upsertMessages(conversationId, [updated]);
    _host.notifyHost();
  }
}
