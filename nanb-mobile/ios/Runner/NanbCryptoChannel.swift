import Flutter
import Foundation
// TODO(ios): confirm Wire's CoreCrypto module name once the package is added
// (CocoaPods pod name / SPM product may expose `WireCoreCrypto` or `CoreCrypto`).
// See docs/ios-mls-build.md §2. Adjust this import + the same TODO line in
// MlsClientHolder.swift / CapturingMlsTransport.swift to the real module.
import WireCoreCrypto

// ============================================================================
// Real CoreCrypto MLS bridge for iOS — parity with Android "Plan B".
//
// This is a direct re-port of the canonical Android dispatch
// (nanb_crypto/android/src/main/kotlin/us/nanb/crypto/NanbCryptoChannel.kt).
// The channel contract (method names, arg keys, return shapes) MUST stay
// byte-for-byte identical to Kotlin and to the Dart `CryptoBridgeNative`
// (lib/core/crypto/crypto_bridge_native.dart) — the same Dart code drives both
// platforms.
//
// State lives in `MlsClientHolder.shared` (the CoreCrypto client + encrypted
// store); commit/welcome bytes produced during add/remove transactions are
// captured by `CapturingMlsTransport.shared`.
//
// ⚠️ AUTHORED ON WINDOWS, NOT YET COMPILED. Every call into the generated
// CoreCrypto Swift bindings whose symbol name is a guess is funnelled through a
// static shim in `// MARK: - CoreCrypto API shims` at the bottom, so each
// fix-up lives in ONE place. Reconcile those against the real bindings on first
// build — see the table in docs/ios-mls-build.md §4. Shims are `static` so the
// `transaction { ctx in … }` closures capture no `self` (avoids Sendable churn).
// ============================================================================

/// Method-channel handler for `nanb.crypto`. Registered from
/// `AppDelegate.didInitializeImplicitFlutterEngine` via `register(with:)`.
final class NanbCryptoChannel {
  static let channelName = "nanb.crypto"

  /// Registers the handler on `messenger`. Called once per implicit Flutter
  /// engine (see AppDelegate). Retention: FlutterMethodChannel holds the
  /// handler closure, which captures `handler`, for the channel's lifetime.
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let handler = NanbCryptoChannel()
    channel.setMethodCallHandler { call, result in
      // CoreCrypto work is async + disk I/O; hop off the platform thread. The
      // reply is marshalled back to main by `reply(_:)` / `fail(_:)`.
      Task { await handler.onCall(call, result: result) }
    }
  }

  // MARK: - Dispatch

  private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    let args = call.arguments as? [String: Any]
    do {
      switch call.method {
      // --- lifecycle ---
      case "mlsInit":
        guard let seed = dataArg(args, "seed") else {
          throw NanbMlsError.missingArgument("missing seed arg")
        }
        guard seed.count == 32 else {
          throw NanbMlsError.invalidArgument("seed must be 32 bytes, got \(seed.count)")
        }
        try await MlsClientHolder.shared.initIfNeeded(seed: seed)
        reply(result, nil)

      case "mlsInitReadOnly":
        guard let seed = dataArg(args, "seed") else {
          throw NanbMlsError.missingArgument("missing seed arg")
        }
        guard seed.count == 32 else {
          throw NanbMlsError.invalidArgument("seed must be 32 bytes, got \(seed.count)")
        }
        try await MlsClientHolder.shared.initReadOnly(seed: seed)
        reply(result, nil)

      case "mlsClientInit":
        guard let clientId = stringArg(args, "clientId"), !clientId.isEmpty else {
          throw NanbMlsError.missingArgument("missing/empty clientId arg")
        }
        // clientId == deviceId; MLS client id is its UTF-8 bytes (matches Kotlin
        // `clientId.encodeToByteArray()` and the sealed-sender attribution path).
        try await MlsClientHolder.shared.ensureMlsClient(clientId: Data(clientId.utf8))
        reply(result, nil)

      case "mlsConsumeStoreReset":
        // Bool over the channel; Dart reads it as bool.
        reply(result, await MlsClientHolder.shared.consumeStoreWasReset())

      case "mlsWipe":
        try await MlsClientHolder.shared.wipe()
        reply(result, nil)

      // --- key packages ---
      case "mintKeyPackages":
        let count = (args?["count"] as? Int) ?? 100
        guard count >= 1, count <= 500 else {
          throw NanbMlsError.invalidArgument("count out of range: \(count)")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        // clientKeypackages(ciphersuite, credentialType, amountRequested) →
        // [KeyPackage]; copyBytes() on each. Kotlin returns List<ByteArray>.
        let packages: [Data] = try await cc.transaction { ctx in
          let kps = try await ctx.clientKeypackages(
            ciphersuite: MlsClientHolder.defaultCiphersuite,
            credentialType: .basic,
            amountRequested: UInt32(count)
          )
          return kps.map { Self.keyPackageBytes($0) }
        }
        // Dart decodes each element as Uint8List (List<int>).
        reply(result, packages.map { FlutterStandardTypedData(bytes: $0) })

      // --- group lifecycle ---
      case "createGroup":
        guard let conversationId = stringArg(args, "conversationId") else {
          throw NanbMlsError.missingArgument("missing conversationId")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        // groupId == conversationId invariant (spec §7.3).
        try await cc.transaction { ctx in
          try await ctx.createConversation(
            conversationId: Self.convId(conversationId),
            creatorCredentialType: .basic,
            config: Self.defaultConversationConfiguration()
          )
        }
        reply(result, conversationId)

      case "addMember":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        guard let peerKeyPackage = dataArg(args, "peerKeyPackage") else {
          throw NanbMlsError.missingArgument("missing peerKeyPackage")
        }
        let bundle = try await addClients(groupId: groupId, keyPackages: [peerKeyPackage])
        reply(result, [
          "welcome": FlutterStandardTypedData(bytes: Self.welcomeBytes(bundle)),
          "commit": FlutterStandardTypedData(bytes: Self.commitBytes(bundle)),
        ])

      case "addMembers":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        let peerKeyPackages: [Data] = (args?["peerKeyPackages"] as? [Any])?
          .compactMap { ($0 as? FlutterStandardTypedData)?.data } ?? []
        guard !peerKeyPackages.isEmpty else {
          throw NanbMlsError.invalidArgument("peerKeyPackages must not be empty")
        }
        // ONE addClientsToConversation for ALL members → a single CommitBundle:
        // one epoch advance, one Welcome covering every added member. Adding one
        // at a time would strand earlier members an epoch behind.
        let bundle = try await addClients(groupId: groupId, keyPackages: peerKeyPackages)
        reply(result, [
          "welcome": FlutterStandardTypedData(bytes: Self.welcomeBytes(bundle)),
          "commit": FlutterStandardTypedData(bytes: Self.commitBytes(bundle)),
        ])

      case "removeMember":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        guard let targetDeviceId = stringArg(args, "targetDeviceId") else {
          throw NanbMlsError.missingArgument("missing targetDeviceId")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        try await cc.transaction { ctx in
          try await ctx.removeClientsFromConversation(
            conversationId: Self.convId(groupId),
            clients: [Self.clientId(targetDeviceId)]
          )
        }
        guard let bundle = CapturingMlsTransport.shared.take() else {
          throw NanbMlsError.noCommitBundle(
            "removeClientsFromConversation did not dispatch a CommitBundle for group \(groupId)")
        }
        // No Welcome on remove — only the Commit to fan out.
        reply(result, FlutterStandardTypedData(bytes: Self.commitBytes(bundle)))

      case "processWelcome":
        guard let welcome = dataArg(args, "welcomeBytes") else {
          throw NanbMlsError.missingArgument("missing welcomeBytes")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        let groupId: String = try await cc.transaction { ctx in
          let welcomeBundle = try await ctx.processWelcomeMessage(
            welcomeMessage: Self.welcome(from: welcome),
            customConfiguration: Self.defaultCustomConfiguration()
          )
          return Self.welcomeBundleIdString(welcomeBundle)
        }
        reply(result, groupId)

      // --- messaging ---
      case "encrypt":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        guard let plaintext = dataArg(args, "plaintext") else {
          throw NanbMlsError.missingArgument("missing plaintext")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        let ciphertext: Data = try await cc.transaction { ctx in
          try await ctx.encryptMessage(
            conversationId: Self.convId(groupId),
            message: plaintext
          )
        }
        reply(result, FlutterStandardTypedData(bytes: ciphertext))

      case "decryptAndInspect":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        guard let ciphertext = dataArg(args, "ciphertext") else {
          throw NanbMlsError.missingArgument("missing ciphertext")
        }
        reply(result, try await decryptAndInspect(groupId: groupId, ciphertext: ciphertext))

      case "processCommit":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        guard let commitBytes = dataArg(args, "commitBytes") else {
          throw NanbMlsError.missingArgument("missing commitBytes")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        // No dedicated processCommit — commits/proposals/app messages all route
        // through decryptMessage; message == nil for commits (discarded).
        try await cc.transaction { ctx in
          _ = try await ctx.decryptMessage(
            conversationId: Self.convId(groupId),
            payload: commitBytes
          )
        }
        reply(result, nil)

      case "currentEpoch":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        // conversationEpoch lives on the transaction context (crypto-ffi
        // core_crypto_context/mls.rs), NOT the top-level client — run it inside a
        // (read-only) transaction. Returns u64.
        let epoch: UInt64 = try await cc.transaction { ctx in
          try await ctx.conversationEpoch(conversationId: Self.convId(groupId))
        }
        // u64 can't cross the channel; cast to Int (Dart int).
        reply(result, Int(epoch))

      case "replaceGroup":
        guard let localGroupId = stringArg(args, "localGroupId") else {
          throw NanbMlsError.missingArgument("missing localGroupId")
        }
        guard let foreignWelcome = dataArg(args, "foreignWelcome") else {
          throw NanbMlsError.missingArgument("missing foreignWelcome")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        // DELIBERATELY two transactions. Wiping + processWelcome in ONE
        // transaction applied the wipe at COMMIT over the group processWelcome
        // had just created under the same id → "Couldn't find conversation" on
        // every later decrypt (found live on Android 2026-06-07). Both call
        // sites are replacing an already-dead/orphaned group, so a failure
        // between the two leaves us no worse off.
        //
        // The wipe is BEST-EFFORT: there may be nothing to replace. CoreCrypto
        // drops the conversation when a Commit removes us from the group, so a
        // re-add Welcome arrives with no local group and wipeConversation
        // throws "Couldn't find conversation". Letting that abort replaceGroup
        // meant a re-invite could never be adopted — the Welcome failed
        // identically on every catchup, forever. Nothing to wipe is exactly the
        // state processWelcomeMessage below wants.
        try? await cc.transaction { ctx in
          try await ctx.wipeConversation(conversationId: Self.convId(localGroupId))
        }
        let newGroupId: String = try await cc.transaction { ctx in
          let welcomeBundle = try await ctx.processWelcomeMessage(
            welcomeMessage: Self.welcome(from: foreignWelcome),
            customConfiguration: Self.defaultCustomConfiguration()
          )
          return Self.welcomeBundleIdString(welcomeBundle)
        }
        reply(result, newGroupId)

      case "wipeGroup":
        guard let groupId = stringArg(args, "groupId") else {
          throw NanbMlsError.missingArgument("missing groupId")
        }
        let cc = try await MlsClientHolder.shared.clientOrThrow()
        try await cc.transaction { ctx in
          try await ctx.wipeConversation(conversationId: Self.convId(groupId))
        }
        reply(result, nil)

      default:
        reply(result, FlutterMethodNotImplemented)
      }
    } catch {
      fail(result, error)
    }
  }

  // MARK: - Shared arms

  /// addClientsToConversation + capture the resulting CommitBundle. Shared by
  /// `addMember` / `addMembers`.
  private func addClients(groupId: String, keyPackages: [Data]) async throws -> CommitBundle {
    let cc = try await MlsClientHolder.shared.clientOrThrow()
    try await cc.transaction { ctx in
      try await ctx.addClientsToConversation(
        conversationId: Self.convId(groupId),
        keyPackages: keyPackages.map { Self.keyPackage(from: $0) }
      )
    }
    guard let bundle = CapturingMlsTransport.shared.take() else {
      throw NanbMlsError.noCommitBundle(
        "addClientsToConversation did not dispatch a CommitBundle for group \(groupId)")
    }
    return bundle
  }

  /// decryptMessage + surface {plaintext, selfRemoved, newEpoch, senderClientId}.
  private func decryptAndInspect(groupId: String, ciphertext: Data) async throws -> [String: Any] {
    let cc = try await MlsClientHolder.shared.clientOrThrow()
    let decrypted = try await cc.transaction { ctx in
      try await ctx.decryptMessage(
        conversationId: Self.convId(groupId),
        payload: ciphertext
      )
    }
    let plaintext: Data? = decrypted.message
    // MLS-authenticated sender: we init each client with clientId == deviceId,
    // so this decodes straight back to the sender's device id. nil for
    // commits/proposals (no application sender).
    let senderClientId: String? = Self.senderClientIdString(decrypted)
    // isActive == false means this Commit removed us from the group.
    let selfRemoved = !decrypted.isActive
    var newEpoch: Int?
    if selfRemoved {
      newEpoch = nil
    } else {
      // conversationEpoch is context-only; query it in a SEPARATE transaction
      // from the decrypt above so a throw here (e.g. the conversation is gone)
      // cannot roll back the already-committed decrypt. nil ⇒ gone/self-removed.
      let epoch: UInt64? = try? await cc.transaction { ctx in
        try await ctx.conversationEpoch(conversationId: Self.convId(groupId))
      }
      newEpoch = epoch.map { Int($0) }
    }
    return [
      "plaintext": plaintext.map { FlutterStandardTypedData(bytes: $0) } ?? NSNull(),
      "selfRemoved": selfRemoved,
      "newEpoch": newEpoch.map { NSNumber(value: $0) } ?? NSNull(),
      "senderClientId": senderClientId ?? NSNull(),
    ]
  }

  // MARK: - Channel arg / reply helpers

  private func dataArg(_ args: [String: Any]?, _ key: String) -> Data? {
    // Dart Uint8List crosses the standard codec as FlutterStandardTypedData.
    (args?[key] as? FlutterStandardTypedData)?.data
  }

  private func stringArg(_ args: [String: Any]?, _ key: String) -> String? {
    args?[key] as? String
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func fail(_ result: @escaping FlutterResult, _ error: Error) {
    DispatchQueue.main.async { result(FlutterError.from(error)) }
  }

  // MARK: - CoreCrypto API shims
  //
  // Every uncertain symbol against the generated CoreCrypto Swift bindings is
  // isolated here so each fix-up is one edit. Cross-reference docs/ios-mls-build.md §4.
  // All `static` (pure) so the transaction closures above capture no `self`.

  /// `ConversationId` from a conversation-id string (UTF-8 bytes).
  /// Confirmed vs v9.3.4: `bytes_wrapper!` → `#[uniffi::constructor] new(bytes: Vec<u8>)`
  /// (crypto-ffi/src/bytes_wrapper.rs), so the Swift init label is `bytes:`.
  static func convId(_ s: String) -> ConversationId {
    ConversationId(bytes: Data(s.utf8))
  }

  /// `ClientId` from a device-id string (UTF-8 bytes).
  /// Confirmed vs v9.3.4: `new(bytes: Vec<u8>)` (crypto-ffi/src/client_id.rs).
  static func clientId(_ s: String) -> ClientId {
    ClientId(bytes: Data(s.utf8))
  }

  /// Wrap raw key-package bytes as the `KeyPackage` addClientsToConversation
  /// takes (`Vec<KeyPackageMaybeArc>`). Confirmed vs v9.3.4: `KeyPackage` is a
  /// `bytes_wrapper!` type with `new(bytes:)` — NOT `MlsKeyPackage`.
  static func keyPackage(from data: Data) -> KeyPackage {
    KeyPackage(bytes: data)
  }

  /// Wrap raw welcome bytes as the `Welcome` processWelcomeMessage takes.
  /// Confirmed vs v9.3.4: `Welcome` is a `bytes_wrapper!` type with `new(bytes:)`.
  static func welcome(from data: Data) -> Welcome {
    Welcome(bytes: data)
  }

  /// Raw bytes of a minted KeyPackage. Confirmed vs v9.3.4: `copy_bytes()` on the
  /// `bytes_wrapper!` type → Swift `copyBytes() -> Data`.
  static func keyPackageBytes(_ kp: KeyPackage) -> Data {
    kp.copyBytes()
  }

  /// Welcome bytes out of a CommitBundle. Confirmed vs v9.3.4:
  /// `CommitBundle.welcome: Option<Welcome>` (crypto-ffi/src/bundles/commit.rs)
  /// → `welcome: Welcome?`; `.copyBytes()` yields the bytes.
  static func welcomeBytes(_ bundle: CommitBundle) -> Data {
    bundle.welcome!.copyBytes()
  }

  /// Commit bytes out of a CommitBundle. Confirmed vs v9.3.4:
  /// `CommitBundle.commit: Vec<u8>` → Swift `commit: Data` directly (no accessor).
  static func commitBytes(_ bundle: CommitBundle) -> Data {
    bundle.commit
  }

  /// groupId string from a WelcomeBundle (its ConversationId bytes → UTF-8).
  /// TODO(ios): Kotlin `welcomeBundle.id.copyBytes().decodeToString()`.
  static func welcomeBundleIdString(_ wb: WelcomeBundle) -> String {
    String(decoding: wb.id.copyBytes(), as: UTF8.self)
  }

  /// Authenticated sender device-id string from a DecryptedMessage, or nil.
  /// TODO(ios): Kotlin `decrypted.senderClientId?.copyBytes()?.decodeToString()`.
  static func senderClientIdString(_ decrypted: DecryptedMessage) -> String? {
    guard let cid = decrypted.senderClientId else { return nil }
    return String(decoding: cid.copyBytes(), as: UTF8.self)
  }

  /// CONVERSATION_CONFIGURATION_DEFAULT equivalent. NOT UniFFI-generated — it's a
  /// Wire *Kotlin* helper constant, so it must be hand-built here.
  /// TODO(ios): reconcile fields against the generated `ConversationConfiguration`
  /// initializer. Guessed shape: ciphersuite + external senders + custom config.
  static func defaultConversationConfiguration() -> ConversationConfiguration {
    ConversationConfiguration(
      ciphersuite: MlsClientHolder.defaultCiphersuite,
      externalSenders: [],
      custom: defaultCustomConfiguration()
    )
  }

  /// CUSTOM_CONFIGURATION_DEFAULT equivalent — also hand-built.
  /// TODO(ios): both fields are optional in Kotlin (nil ⇒ library defaults).
  static func defaultCustomConfiguration() -> CustomConfiguration {
    CustomConfiguration(keyRotationSpan: nil, wirePolicy: nil)
  }
}
