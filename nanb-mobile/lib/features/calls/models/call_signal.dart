import 'dart:convert';

/// The kinds of media a call can carry. Audio ships first; [video] is reserved
/// for the next phase (see `docs/voice-calls-design.md`).
enum CallMediaKind { audio, video }

/// Why a call ended — carried on `decline`/`hangup` signals and surfaced in the
/// local call log. `busy` is a decline because the callee is already in a call.
enum CallEndReason { hangup, declined, busy, missed, failed, cancelled }

/// The signaling messages exchanged to set up and tear down a 1:1 call. They
/// ride the **same E2EE pipeline as chat** — encoded as a compact JSON control
/// payload inside the encrypted body (`invite`, the ring, travels the stored
/// delivery path so it can wake the device via push; the fast media-negotiation
/// frames travel the WebSocket *ephemeral* channel). The server only ever sees
/// ciphertext; the SDP/ICE never touch it in the clear.
///
/// Mirrors the `MessageControl` / `TtlHeader` idiom: a single discriminator key
/// (`_call`) plus compact field keys, and a fast-rejecting [tryDecode].
class CallSignal {
  const CallSignal._({
    required this.type,
    required this.callId,
    this.mediaKind,
    this.fromDeviceId,
    this.sdp,
    this.candidate,
    this.candidates,
    this.seq,
    this.reason,
  });

  /// The caller invites the callee to a call (the "ring"). Carries the media
  /// kind and the caller's device id.
  factory CallSignal.invite({
    required String callId,
    required CallMediaKind mediaKind,
    required String fromDeviceId,
  }) =>
      CallSignal._(
        type: CallSignalType.invite,
        callId: callId,
        mediaKind: mediaKind,
        fromDeviceId: fromDeviceId,
      );

  /// The callee's device acknowledges the ring (UI: "ringing…"). Does not imply
  /// the user accepted yet.
  factory CallSignal.ringing(String callId) =>
      CallSignal._(type: CallSignalType.ringing, callId: callId);

  /// The callee accepted. Carries the accepting device id so the caller pins the
  /// winning device (multi-device: first accept wins, the rest are cancelled).
  factory CallSignal.accept({
    required String callId,
    required String fromDeviceId,
  }) =>
      CallSignal._(
        type: CallSignalType.accept,
        callId: callId,
        fromDeviceId: fromDeviceId,
      );

  /// The callee declined (optionally because they were [CallEndReason.busy]).
  factory CallSignal.decline(String callId, {CallEndReason? reason}) =>
      CallSignal._(
        type: CallSignalType.decline,
        callId: callId,
        reason: reason ?? CallEndReason.declined,
      );

  /// A "stop ringing" signal with two uses, distinguished by [exceptDeviceId]:
  ///  - **give-up** (caller abandoned before anyone answered): [exceptDeviceId]
  ///    is null → every still-ringing/connecting callee device tears down.
  ///  - **answered-elsewhere** (first accept won): [exceptDeviceId] is the
  ///    WINNING (accepting) device, so that device IGNORES this cancel — it's
  ///    the one that answered — while the peer's OTHER devices stop ringing.
  ///    Without this, the caller's own stop-other-rings cancel would tear down
  ///    the very device that just accepted (it's `connecting`, which the cancel
  ///    handler tears down).
  factory CallSignal.cancel(String callId, {String? exceptDeviceId}) =>
      CallSignal._(
        type: CallSignalType.cancel,
        callId: callId,
        fromDeviceId: exceptDeviceId,
      );

  /// SDP offer (caller → callee, after accept). [seq] numbers the caller's
  /// offers within one call (a re-sent offer keeps its number; an ICE-restart
  /// offer gets the next one) so a late answer to a SUPERSEDED offer can be told
  /// apart from the answer to the current one. Optional on the wire: a peer
  /// that predates it sends/echoes none.
  factory CallSignal.offer({
    required String callId,
    required String sdp,
    int? seq,
  }) =>
      CallSignal._(
          type: CallSignalType.offer, callId: callId, sdp: sdp, seq: seq);

  /// SDP answer (callee → caller). [seq] echoes the answered offer's [seq].
  factory CallSignal.answer({
    required String callId,
    required String sdp,
    int? seq,
  }) =>
      CallSignal._(
          type: CallSignalType.answer, callId: callId, sdp: sdp, seq: seq);

  /// A trickled ICE candidate. [candidate] is the standard
  /// `{candidate, sdpMid, sdpMLineIndex}` map.
  factory CallSignal.ice({
    required String callId,
    required Map<String, dynamic> candidate,
  }) =>
      CallSignal._(
        type: CallSignalType.ice,
        callId: callId,
        candidate: candidate,
      );

  /// Several trickled ICE candidates in ONE signal. Each signal is a full E2EE
  /// submit serialised on the conversation's FIFO lock, so candidates gathered
  /// while an earlier send is in flight are coalesced into one envelope instead
  /// of each paying its own round trip.
  ///
  /// Wire-compatible with peers that only know [CallSignal.ice]: the FIRST
  /// candidate also rides the legacy single-candidate key, so an older client
  /// still applies one candidate rather than dropping the whole frame. A
  /// one-element batch is exactly the legacy [CallSignal.ice] shape.
  factory CallSignal.iceBatch({
    required String callId,
    required List<Map<String, dynamic>> candidates,
  }) {
    assert(candidates.isNotEmpty);
    return CallSignal._(
      type: CallSignalType.ice,
      callId: callId,
      candidate: candidates.first,
      candidates: candidates.length > 1 ? candidates : null,
    );
  }

  /// Either side ends an established (or connecting) call.
  factory CallSignal.hangup(String callId, {CallEndReason? reason}) =>
      CallSignal._(
        type: CallSignalType.hangup,
        callId: callId,
        reason: reason ?? CallEndReason.hangup,
      );

  final CallSignalType type;

  /// Random per-call id minted by the caller; correlates every signal in a call.
  final String callId;

  /// Set on [CallSignalType.invite].
  final CallMediaKind? mediaKind;

  /// Set on `invite` (caller's device), `accept` (accepting device), and
  /// `cancel` (the WINNING device to exclude — see [CallSignal.cancel]).
  final String? fromDeviceId;

  /// Set on `offer` / `answer`.
  final String? sdp;

  /// Set on `ice` — `{candidate, sdpMid, sdpMLineIndex}`.
  final Map<String, dynamic>? candidate;

  /// Set on a batched `ice` ([CallSignal.iceBatch]) with more than one entry.
  /// Read [iceCandidates] rather than this directly.
  final List<Map<String, dynamic>>? candidates;

  /// Optional offer number on `offer`, echoed on `answer`. See
  /// [CallSignal.offer].
  final int? seq;

  /// Every ICE candidate this `ice` signal carries — the batch when present,
  /// else the single legacy [candidate]. Empty for any other signal type.
  List<Map<String, dynamic>> get iceCandidates {
    final batch = candidates;
    if (batch != null && batch.isNotEmpty) return batch;
    final single = candidate;
    return single == null ? const [] : [single];
  }

  /// Set on `decline` / `hangup`.
  final CallEndReason? reason;

  String encode() {
    final m = <String, dynamic>{'_call': type.name, 'cid': callId};
    if (mediaKind != null) m['mk'] = mediaKind!.name;
    if (fromDeviceId != null) m['dev'] = fromDeviceId;
    if (sdp != null) m['sdp'] = sdp;
    if (candidate != null) m['c'] = candidate;
    if (candidates != null) m['cs'] = candidates;
    if (seq != null) m['sq'] = seq;
    if (reason != null) m['r'] = reason!.name;
    return jsonEncode(m);
  }

  /// Returns the call signal if [body] is one, else null. Fast-rejects anything
  /// that isn't a JSON object so normal text never pays the parse — same guard
  /// as [MessageControl.tryDecode].
  static CallSignal? tryDecode(String body) {
    if (body.isEmpty || body.codeUnitAt(0) != 0x7B /* '{' */) return null;
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final typeName = raw['_call'];
    if (typeName is! String) return null;
    final type = CallSignalType.values
        .cast<CallSignalType?>()
        .firstWhere((t) => t!.name == typeName, orElse: () => null);
    if (type == null) return null;
    final cid = raw['cid'];
    if (cid is! String || cid.isEmpty) return null;

    switch (type) {
      case CallSignalType.invite:
        final dev = raw['dev'];
        if (dev is! String) return null;
        return CallSignal.invite(
          callId: cid,
          mediaKind: _mediaKind(raw['mk']) ?? CallMediaKind.audio,
          fromDeviceId: dev,
        );
      case CallSignalType.ringing:
        return CallSignal.ringing(cid);
      case CallSignalType.accept:
        final dev = raw['dev'];
        if (dev is! String) return null;
        return CallSignal.accept(callId: cid, fromDeviceId: dev);
      case CallSignalType.decline:
        return CallSignal.decline(cid, reason: _reason(raw['r']));
      case CallSignalType.cancel:
        final dev = raw['dev'];
        return CallSignal.cancel(cid,
            exceptDeviceId: dev is String ? dev : null);
      case CallSignalType.offer:
        final sdp = raw['sdp'];
        if (sdp is! String || sdp.isEmpty) return null;
        return CallSignal.offer(callId: cid, sdp: sdp, seq: _seq(raw['sq']));
      case CallSignalType.answer:
        final sdp = raw['sdp'];
        if (sdp is! String || sdp.isEmpty) return null;
        return CallSignal.answer(callId: cid, sdp: sdp, seq: _seq(raw['sq']));
      case CallSignalType.ice:
        final c = raw['c'];
        if (c is! Map) return null;
        final batch = _candidateList(raw['cs']);
        return CallSignal.iceBatch(
          callId: cid,
          candidates: batch ?? [_stringKeyed(c)],
        );
      case CallSignalType.hangup:
        return CallSignal.hangup(cid, reason: _reason(raw['r']));
    }
  }

  static Map<String, dynamic> _stringKeyed(Map<Object?, Object?> m) =>
      m.map((k, v) => MapEntry(k.toString(), v));

  /// The batched `cs` list, or null when absent/empty/malformed (the caller
  /// then falls back to the single legacy `c`).
  static List<Map<String, dynamic>>? _candidateList(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is! Map) return null;
      out.add(_stringKeyed(e));
    }
    return out;
  }

  static int? _seq(Object? raw) => raw is int ? raw : null;

  static CallMediaKind? _mediaKind(Object? name) {
    if (name is! String) return null;
    for (final k in CallMediaKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }

  static CallEndReason? _reason(Object? name) {
    if (name is! String) return null;
    for (final r in CallEndReason.values) {
      if (r.name == name) return r;
    }
    return null;
  }
}

/// The wire discriminator for a [CallSignal]. Lower-case names are the on-wire
/// `_call` values; keep them stable.
enum CallSignalType {
  invite,
  ringing,
  accept,
  decline,
  cancel,
  offer,
  answer,
  ice,
  hangup,
}
