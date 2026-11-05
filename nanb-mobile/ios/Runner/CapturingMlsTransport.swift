// Active as of the iOS MLS integration (docs/ios-mls-build.md). Captures the
// CommitBundle CoreCrypto dispatches during add/remove transactions. Authored on
// Windows and NOT yet compiled; reconcile CommitBundle field names against the
// generated bindings (§4 — this is the single most likely fix-up site).
import Foundation
// TODO(ios): confirm Wire's CoreCrypto module name (WireCoreCrypto vs CoreCrypto).
import WireCoreCrypto

// NOTE: this file references CoreCrypto UniFFI types (`MlsTransport`,
// `CommitBundle`, `MlsTransportResponse`, `HistorySecret`). Those symbols come
// from Wire's published CoreCrypto Swift package (see docs/ios-mls-build.md).
// Until that dependency is added this file will NOT compile.

/// Captures `CommitBundle`s dispatched by CoreCrypto so the channel-side
/// `addMember` / `removeMember` handlers can read the Welcome/Commit bytes
/// synchronously after a transaction completes. Direct port of the Android
/// `CapturingMlsTransport` (nanb_crypto/.../CapturingMlsTransport.kt).
///
/// CoreCrypto dispatches commits through `sendCommitBundle` DURING the
/// `addClientsToConversation` / `removeClientsFromConversation` transaction,
/// before the call returns to our `await`. We stash the bundle behind a lock
/// (the Swift equivalent of Kotlin's `AtomicReference`) so the channel arm can
/// `take()` it immediately afterwards.
///
/// CommitBundle field names (`welcome`, `commit`) below mirror the Kotlin
/// bindings; verify against the GENERATED Swift bindings — UniFFI may surface
/// them as `welcome: Welcome?` + `commit: Data`, or with `.bytes` accessors.
/// This is the single most likely place to need an Xcode fix-up.
///
/// Plan C will replace this with a transport that ALSO posts the commit
/// bundle to the server via POST /messages.
final class CapturingMlsTransport: MlsTransport {
  /// Process-wide instance shared by `MlsClientHolder.provideTransport`.
  static let shared = CapturingMlsTransport()

  private let lock = NSLock()
  private var lastBundle: CommitBundle?

  func sendCommitBundle(commitBundle: CommitBundle) async -> MlsTransportResponse {
    lock.lock()
    lastBundle = commitBundle
    lock.unlock()
    return .success
  }

  func sendMessage(mlsMessage: Data) async -> MlsTransportResponse {
    // No-op: application messages go through our own POST /messages pipeline
    // on the Dart side, not via this transport.
    return .success
  }

  // Confirmed vs v9.3.4 (crypto-ffi core_crypto/mls_transport.rs): the trait's
  // `prepare_for_transport(history_secret: HistorySecretFfi) -> MlsTransportData`.
  // `HistorySecretFfi` is a file-local alias of the exported `HistorySecret`
  // Record (ephemeral.rs). `MlsTransportData` is a `uniffi::custom_type!` over
  // `Vec<u8>` → a `Data` typealias in Swift, so returning `Data` satisfies it.
  // Never actually called: we never enable history sharing.
  func prepareForTransport(historySecret: HistorySecret) async -> Data {
    return Data()
  }

  /// Takes the most recently captured bundle and clears the slot. Returns
  /// nil if `sendCommitBundle` was not called (treat as an error at the call
  /// site — CoreCrypto optimised the commit away).
  func take() -> CommitBundle? {
    lock.lock()
    defer { lock.unlock() }
    let b = lastBundle
    lastBundle = nil
    return b
  }
}
