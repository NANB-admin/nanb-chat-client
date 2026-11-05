/// The result of the iOS Notification Service Extension's last attempt to send
/// a closed-app sealed "delivered" receipt, mirrored out of the App Group.
///
/// The extension is a separate process with no console on a store build, and
/// every failure there is silent by design (best-effort; the foreground catchup
/// is the backstop). This carries the stage tag it reached so the app can say
/// which step failed without a special debug build.
///
/// [stage] is one of the tags in `SealedReceiptSender.Outcome` — `sent` means
/// the POST completed (check [httpStatus] for the server's answer), `skiptor`
/// means it deliberately declined because built-in Tor is on, `nopayload` means
/// the push carried no inlined sealed blob to work from, and the rest name the
/// step that failed (`nox25519`, `sealfail`, `innerempty`, `blocked`,
/// `nopeerkeys`, `noidentity`, `sealoutfail`, `neturl`).
class NseReceiptOutcome {
  const NseReceiptOutcome({
    required this.stage,
    required this.at,
    this.httpStatus,
    this.note,
  });

  /// Parses the JSON `NseReceiptLog` writes, or null if it is absent/malformed.
  static NseReceiptOutcome? fromJson(Map<String, Object?> json) {
    final stage = json['stage'];
    final at = json['at'];
    if (stage is! String || stage.isEmpty || at is! int) return null;
    final http = json['http'];
    final note = json['note'];
    return NseReceiptOutcome(
      stage: stage,
      at: DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true),
      httpStatus: http is int ? http : null,
      note: note is String && note.isNotEmpty ? note : null,
    );
  }

  final String stage;
  final DateTime at;
  final int? httpStatus;
  final String? note;

  /// Whether the receipt actually reached the server with a success status.
  bool get delivered => stage == 'sent' && (httpStatus ?? 0) >= 200 && (httpStatus ?? 0) < 300;

  /// A one-line, human-readable summary for a diagnostics row.
  String get summary {
    final detail = httpStatus?.toString() ?? note;
    return detail == null ? stage : '$stage · $detail';
  }
}
