/// Sealed-sender Phase 2 (unidentified access) — the client seam that exposes
/// this account's unidentified-access key (UAK) and its server commitment.
///
/// The UAK is a stable high-entropy secret derived from the account's X25519
/// identity (phrase-derived + immutable, so the UAK survives a recovery-phrase
/// restore without any stored state). The account:
///   - publishes the COMMITMENT `H(UAK)` to the server (`POST /accounts/me/
///     access-key`), never the UAK itself;
///   - shares the raw UAK with its CONTACTS over the E2EE channel;
/// so a contact can present the UAK on the unauthenticated sealed-send path and
/// the server verifies `H(presented) == commitment` — authorizing the deposit
/// without learning which contact sent it.
///
/// A narrow seam (separate from `CryptoBridge`, like `SealOpener`) so only the
/// real bridges — which hold this device's X25519 private key — implement it and
/// the many `CryptoBridge` test fakes don't have to.
abstract interface class UnidentifiedAccessProvider {
  /// This account's UAK (32 bytes). Presented (raw) on the unauthenticated
  /// sealed-send path and shared with contacts over E2EE.
  Future<List<int>> unidentifiedAccessKey();

  /// The commitment `H(UAK) = SHA-256(UAK)` (32 bytes) published to the server.
  Future<List<int>> unidentifiedAccessCommitment();
}
