/// Canonical values for the NON-encrypted `push_kind` hint that shapes the
/// offline wakeup push (see [SubmitMessagePayload.pushKind] and
/// `WakeupPayload.pushKind`). The content stays end-to-end encrypted — this
/// hint only tells the server which *style* of wakeup to send.
abstract final class PushKind {
  /// Ring a closed/locked device (full-screen incoming-call notification)
  /// instead of showing a generic "new message" banner.
  static const call = 'call';

  /// A pure control/protocol envelope (read/delivery receipt, reaction, pin,
  /// request-decision, MLS Welcome, sealed-sender access-key share, non-invite
  /// call signal). It carries no user-visible content, so it must NEVER raise a
  /// "new message" banner: the server skips the offline wakeup entirely, and a
  /// background isolate that still receives one (a mixed-version fleet) drops
  /// the banner instead of buzzing the device.
  static const silent = 'silent';

  /// Someone reacted to a message. It is a control envelope (nothing to render
  /// as a bubble) but, unlike the others, the recipient wants to hear about it,
  /// so the server treats it as a normal offline wakeup (generic "New message"
  /// banner). Removing a reaction stays [silent].
  static const reaction = 'reaction';
}

/// The push kind for a CONTENT copy addressed to [recipientAccountId].
///
/// A copy fanned out to the sender's OWN account (self-sync to their other
/// devices) must never raise a "new message" banner there — the user just wrote
/// it. The wakeup push is content-blind, so the only way to stop the banner is
/// to ask the server not to push at all ([PushKind.silent]); the sibling still
/// receives the envelope over its socket or on its next catchup. [requested]
/// (e.g. a call hint) always wins, and any other account keeps the normal
/// wakeup (null).
String? pushKindForRecipient({
  required String recipientAccountId,
  required String? selfAccountId,
  String? requested,
}) {
  if (requested != null) return requested;
  if (selfAccountId != null &&
      selfAccountId.isNotEmpty &&
      recipientAccountId == selfAccountId) {
    return PushKind.silent;
  }
  return null;
}
