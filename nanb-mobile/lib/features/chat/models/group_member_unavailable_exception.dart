/// Thrown by group creation/add when a prospective member has no usable MLS
/// KeyPackage (pool exhausted / never came online), so we can't add them as an
/// MLS leaf. Surfaced to the user with the member's name rather than a cryptic
/// crash.
class GroupMemberUnavailableException implements Exception {
  const GroupMemberUnavailableException(this.username);
  final String username;
  @override
  String toString() =>
      '$username has no encryption keys available right now — they may need to '
      'open the app first. Try again in a moment.';
}
