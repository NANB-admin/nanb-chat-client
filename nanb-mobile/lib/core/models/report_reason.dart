/// Why a user is being reported. The [wire] value is the canonical string the
/// server validates against (see nanb-server `internal/moderation`); the
/// human-facing label lives in the report UI, not here, so this stays a pure
/// data type with no presentation coupling.
enum ReportReason {
  spam('spam'),
  harassment('harassment'),
  threats('threats'),
  sexualContent('sexual_content'),
  childSafety('child_safety'),
  impersonation('impersonation'),
  other('other');

  const ReportReason(this.wire);

  /// The value sent in the `reason` field of `POST /reports`.
  final String wire;
}
