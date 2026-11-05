import 'package:flutter/foundation.dart';

/// Return value of [CryptoBridge.addMember]. Carries both the Welcome bytes
/// (sent to the new member's device) and the Commit bytes (fanned out to each
/// existing member's device so their MLS state advances to the new epoch).
@immutable
class AddMemberResult {
  const AddMemberResult({required this.welcome, required this.commit});

  /// Welcome bytes to deliver to the newly added member's device via
  /// `envelopeType: mls_welcome`.
  final List<int> welcome;

  /// Commit bytes to fan out to every existing group member's device via
  /// `envelopeType: mls_handshake` so their CoreCrypto state advances.
  final List<int> commit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AddMemberResult &&
          listEquals(welcome, other.welcome) &&
          listEquals(commit, other.commit);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(welcome), Object.hashAll(commit));
}
