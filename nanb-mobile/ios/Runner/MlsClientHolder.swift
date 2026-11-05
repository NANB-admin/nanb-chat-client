// Active as of the iOS MLS integration (docs/ios-mls-build.md). Real CoreCrypto
// bridge groundwork — the CoreCrypto Swift symbols it references are provided by
// Wire's package added in ios/Podfile. Authored on Windows and NOT yet compiled;
// reconcile any symbol-name mismatches against the generated bindings (§4).
import Foundation
// TODO(ios): confirm Wire's CoreCrypto module name (WireCoreCrypto vs CoreCrypto).
import WireCoreCrypto

// NOTE: references CoreCrypto UniFFI types (`CoreCrypto`, `DatabaseKey`,
// `Ciphersuite`, `ClientId`, `coreCryptoDeferredInit`). Those come from Wire's
// published CoreCrypto Swift package (see docs/ios-mls-build.md).

/// Process-wide singleton holding the CoreCrypto client + its store location.
/// Channel methods route through this — exactly one CoreCrypto instance per
/// running app process (spec §7.3). Direct port of the Android
/// `MlsClientHolder` object (nanb_crypto/.../MlsClientHolder.kt).
///
/// Concurrency: an `actor` serialises access the way Kotlin's `synchronized(this)`
/// did. CoreCrypto's own internal locking handles its store concurrency.
/// `client()` hands the live instance to the channel, which then runs
/// `transaction { … }` blocks against it (CoreCrypto serialises those too).
///
/// CoreCrypto v9 requires `provideTransport()` BEFORE `mlsInit()`. We install
/// `CapturingMlsTransport.shared` so `addMember` can return Welcome bytes to Dart.
actor MlsClientHolder {
  static let shared = MlsClientHolder()

  /// Default ciphersuite — RFC 9420 MLS_128 baseline (matches Android).
  /// VERIFY the generated Swift enum case name; UniFFI lower-camels it, so
  /// `MLS_128_DHKEMX25519_AES128GCM_SHA256_ED25519` likely becomes
  /// `.mls128Dhkemx25519Aes128gcmSha256Ed25519`.
  static let defaultCiphersuite: Ciphersuite = .mls128Dhkemx25519Aes128gcmSha256Ed25519

  // Qualified: `import WireCoreCrypto` re-exports WireCoreCryptoUniffi via
  // `@_exported`, so the bare name `CoreCrypto` is ambiguous (the ergonomic
  // wrapper class vs the raw uniffi `WireCoreCryptoUniffi.CoreCrypto`). We hold
  // the WRAPPER — its `transaction`/`provideTransport` are what the channel drives.
  private var client: WireCoreCrypto.CoreCrypto?
  private var dbPath: String?
  private var mlsClientInited = false

  /// Set whenever the store is purged and rebuilt. Every KeyPackage this device
  /// has ever published holds a private key that lived in the destroyed store,
  /// so the whole published pool is dead and the server has to be told to drop
  /// it — see `consumeStoreWasReset`.
  private var storeWasReset = false

  /// Opens the CoreCrypto store (foreground / writer path) and installs the
  /// transport. Idempotent — second call is a no-op.
  func initIfNeeded(seed: Data) async throws {
    if client != nil { return }
    let path = try storePath()
    let key = deriveStoreKey(seed: seed)
    let cc = try await openStore(path: path, key: key)
    // CoreCrypto v9 needs provideTransport before any mlsInit transaction.
    // Ergonomic wrapper label is `transport:` (WireCoreCrypto/CoreCrypto.swift
    // `provideTransport(transport: any MlsTransport)`), NOT the raw uniffi
    // `callbacks:`. Confirmed vs v9.3.4.
    try await cc.provideTransport(transport: CapturingMlsTransport.shared)
    client = cc
    dbPath = path
  }

  /// Opens CoreCrypto for the background path (e.g. an NSE/decrypt-only
  /// context). On iOS there is no separate FCM background isolate as on
  /// Android, but a Notification Service Extension would use this. WAL mode
  /// allows a concurrent reader. We still install the capturing transport
  /// because a cold start must run `ensureMlsClient` before it can decrypt;
  /// decryption never produces commits, so nothing is sent.
  func initReadOnly(seed: Data) async throws {
    if client != nil { return }
    let path = try storePath()
    let key = deriveStoreKey(seed: seed)
    let cc = try await openStore(path: path, key: key)
    // Ergonomic wrapper label is `transport:` (WireCoreCrypto/CoreCrypto.swift
    // `provideTransport(transport: any MlsTransport)`), NOT the raw uniffi
    // `callbacks:`. Confirmed vs v9.3.4.
    try await cc.provideTransport(transport: CapturingMlsTransport.shared)
    client = cc
    dbPath = path
  }

  /// Runs CoreCrypto's deferred `mlsInit` with the server-assigned device id.
  /// Required before any MLS op (clientKeypackages, createConversation, …).
  /// Idempotent per process; across restarts CoreCrypto loads the existing
  /// client from the store (same call, same client id).
  func ensureMlsClient(clientId: Data) async throws {
    if mlsClientInited { return }
    let cc = try clientOrThrow()
    try await cc.transaction { ctx in
      // ClientId ctor label is `bytes:` (crypto-ffi client_id.rs `new(bytes:)`).
      // `ciphersuites` is `[Ciphersuite]` — confirmed vs v9.3.4: crypto-ffi
      // ciphersuite.rs declares `type Ciphersuites = Vec<Ciphersuite>`, and
      // `Ciphersuite` is a `uniffi::Enum`. `nbKeyPackage` is `Option<u32>`.
      try await ctx.mlsInit(
        clientId: ClientId(bytes: clientId),
        ciphersuites: [MlsClientHolder.defaultCiphersuite],
        nbKeyPackage: 100
      )
    }
    mlsClientInited = true
  }

  /// Reports whether the store has been purged+rebuilt since the last call,
  /// clearing the flag.
  ///
  /// Dart uses this to republish its KeyPackage pool with `reset: true` so the
  /// server DROPS the dead packages. Publishing more without the purge would
  /// not help: the pool still reads as full to the replenisher's low-water
  /// check, and the server pops FIFO, so peers keep drawing the dead ones and
  /// every Welcome built from them is undecryptable — the exact failure the
  /// restore path already purges for, server-side.
  func consumeStoreWasReset() -> Bool {
    let was = storeWasReset
    storeWasReset = false
    return was
  }

  /// Returns the live client for the channel to run transactions against.
  func clientOrThrow() throws -> WireCoreCrypto.CoreCrypto {
    guard let c = client else {
      throw NanbMlsError.notInitialized
    }
    return c
  }

  /// Closes the store and deletes the on-disk file (+ WAL/SHM sidecars) AND the
  /// keychain salt paired with it. Dropping the file alone would leave the next
  /// open re-applying a stale `PRAGMA cipher_salt` to a brand-new database —
  /// see CoreCryptoKeychainSalt for why the two are one unit on iOS.
  func wipe() throws {
    let path = dbPath ?? ((try? storePath()) ?? "")
    // UniFFI objects free on deinit; there may be no explicit close() in the
    // generated Swift. If the bindings DO expose one, call it here. Dropping
    // the reference releases the Rust handle.
    client = nil
    dbPath = nil
    mlsClientInited = false
    if !path.isEmpty {
      purgeStore(at: path)
    }
  }

  // MARK: - private

  /// `<AppSupport>/corecrypto.db` — the iOS analogue of Android's
  /// `filesDir/corecrypto.db`. Application Support is app-private and not
  /// exposed in the Files app. We create the directory if missing (iOS does
  /// not guarantee it exists).
  private func storePath() throws -> String {
    let fm = FileManager.default
    let dir = try fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return dir.appendingPathComponent("corecrypto.db").path
  }

  /// Opens (or creates) the store. Recovery mirrors Android: the store key is
  /// DETERMINISTIC from the identity seed, so if the correct key can't open an
  /// existing file it belongs to a different identity (or is corrupt) and is
  /// unusable. On ANY open failure we purge the store (file + sidecars +
  /// keychain salt) and retry once. A returning user with the correct seed
  /// opens first try and never reaches the recovery path.
  ///
  /// Recovery is deliberately NOT conditioned on the error text any more. It
  /// used to fire only for `not a database` / `code 26`, which left the real
  /// iOS failure — a bare `Error code 1: SQL error or missing database`, raised
  /// when the db file and its keychain salt have come apart — permanently
  /// unrecoverable: every retry, sign-up AND recovery-phrase restore alike,
  /// re-hit the same unopenable file and threw before the user could get in.
  /// Matching on the message could only ever cover the failures we had already
  /// seen, so it doesn't gate the recovery at all now.
  ///
  /// The trade this accepts: an open that fails for some transient reason costs
  /// the local MLS state (groups re-establish on next contact — the app already
  /// handles that path). Being wrong in the other direction bricks onboarding.
  private func openStore(path: String, key: Data) async throws -> WireCoreCrypto.CoreCrypto {
    // Use the ergonomic wrapper init (WireCoreCrypto/CoreCrypto.swift:
    // `convenience init(keystorePath:key:) async throws`, which internally calls
    // `coreCryptoDeferredInit(path:key:entropySeed:nil)`). Calling the raw uniffi
    // free func directly would yield a `WireCoreCryptoUniffi.CoreCrypto`, not the
    // wrapper whose `transaction`/`provideTransport` we rely on. `DatabaseKey` is
    // a throwing ctor with label `key:` (crypto-ffi database/key.rs `new(key:)`);
    // the outer `try` covers it. Confirmed vs v9.3.4.
    do {
      return try await WireCoreCrypto.CoreCrypto(
        keystorePath: path,
        key: DatabaseKey(key: key)
      )
    } catch {
      let firstError = error
      // Recover before destroying: if the container path moved under an app
      // update, the salt is still in the keychain under the old path's hash.
      // Re-filing it keeps every MLS group; purging loses them all. Only with
      // the db file present — a stale salt on a NEW file is its own brick.
      if FileManager.default.fileExists(atPath: path),
        CoreCryptoKeychainSalt.adoptOrphan(forStorePath: path),
        let recovered = try? await WireCoreCrypto.CoreCrypto(
          keystorePath: path,
          key: DatabaseKey(key: key)
        )
      {
        return recovered
      }
      purgeStore(at: path)
      do {
        return try await WireCoreCrypto.CoreCrypto(
          keystorePath: path,
          key: DatabaseKey(key: key)
        )
      } catch {
        // Both attempts failed, so this is not a stale-store problem. Carry
        // BOTH errors plus the path: the first one is what the store actually
        // died of, and without the path there is no way to tell an
        // Application-Support problem from a CoreCrypto one in a report from a
        // TestFlight device we can't attach a debugger to.
        throw NanbMlsError.storeOpenFailed(
          "CoreCrypto store at \(path) failed to open, and failed again after "
            + "a purge. first=\(firstError) retry=\(error)")
      }
    }
  }

  /// Deletes every piece of the store: the db file, its WAL/SHM sidecars, and
  /// the keychain salt CoreCrypto pairs with that path on iOS. All-or-nothing
  /// on purpose — a half-purge is what produces an unopenable store in the
  /// first place (see CoreCryptoKeychainSalt).
  private func purgeStore(at path: String) {
    let fm = FileManager.default
    for p in [path, "\(path)-wal", "\(path)-shm"] {
      try? fm.removeItem(atPath: p)
    }
    CoreCryptoKeychainSalt.delete(forStorePath: path)
    storeWasReset = true
  }

  /// HKDF(seed, info = "nanb-corecrypto-store-v1") → 32-byte store key.
  /// Same seed always produces the same key, so a re-mount after process
  /// restart works without re-key. MUST match the Android derivation.
  private func deriveStoreKey(seed: Data) -> Data {
    let info = Data("nanb-corecrypto-store-v1".utf8)
    return Hkdf.derive(ikm: seed, salt: Data(), info: info, length: 32)
  }
}

/// Local errors that don't originate from CoreCrypto. Mapped to channel codes
/// by `FlutterError.from(_:)` in MlsExceptions.swift. Named with a `Nanb`
/// prefix so it never collides with a UniFFI-generated `MlsError`/`MlsException`.
enum NanbMlsError: Error {
  case notInitialized
  case missingArgument(String)
  case invalidArgument(String)
  case noCommitBundle(String)
  /// The CoreCrypto store could not be opened even after a purge + retry.
  /// Carries both underlying errors and the path — this is the one MLS failure
  /// a user can hit before they even have an account, so it has to be
  /// diagnosable from the on-screen message alone.
  case storeOpenFailed(String)
}
