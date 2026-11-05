# iOS MLS — build & integration guide

Status: **full MLS dispatch authored + API-reconciled against the v9.3.4 source;
awaiting first compile.** As of this pass the ratchet-only stub is gone:
`ios/Runner/NanbCryptoChannel.swift` now dispatches all 16 MLS methods against
`MlsClientHolder.shared` (a direct re-port of the Android `NanbCryptoChannel.kt`),
the `#if false` guards are removed from `MlsClientHolder.swift` /
`CapturingMlsTransport.swift` / `MlsExceptions.swift`, and CoreCrypto is
integrated as a **vendored XCFramework** (see below), not a CocoaPod.

Integration shape (supersedes §2 below): Wire publishes **no CocoaPod**. Release
`v9.3.4` (which matches the Android `core-crypto-android:9.3.4` AAR) ships two
prebuilt XCFrameworks as assets — `WireCoreCrypto.xcframework.zip` (the ergonomic
Swift wrapper you `import`; it `@_exported`-re-exports the uniffi module) and
`WireCoreCryptoUniffi.xcframework.zip` (the generated bindings). They are vendored
via a local podspec `ios/NanbCoreCrypto/NanbCoreCrypto.podspec` (the NanbArti
pattern), fetched from the GitHub release into `NanbCoreCrypto/frameworks/` by a
new `ios.yml` step. `ios/Podfile` declares `pod 'NanbCoreCrypto', :path => …`.

Most of the §4 API names are now **resolved from the published v9.3.4 Rust/Swift
source** (marked "Confirmed vs v9.3.4" in the Swift comments): the context method
signatures, `CommitBundle.commit: Data` / `.welcome: Welcome?`, the `bytes:`
constructor label on `ConversationId`/`ClientId`/`KeyPackage`/`Welcome`,
`DatabaseKey(key:)` (throwing), `provideTransport(transport:)`, the ergonomic
`CoreCrypto(keystorePath:key:)` init, and that `conversationEpoch` is
context-only; `ciphersuites` is `[Ciphersuite]` (`type Ciphersuites =
Vec<Ciphersuite>`); and all three `MlsTransport` methods in
`CapturingMlsTransport.swift` match (`MlsTransportData` is a `Data` typealias via
`custom_type!`, `HistorySecret` is the exported Record). **Still not compiled**,
so the one genuine unknown left is the exact framework **module name at link
time** (`import WireCoreCrypto` is near-certain — the xcframework is named
`WireCoreCrypto.xcframework` — but only a build confirms it). The remaining work
is to run `ios.yml` (or a Mac) and clear any stragglers.

`Hkdf.swift` stays live — it's pure CryptoKit and was never guarded.

Everything below is the original procedure + the API mismatches to expect (now
mostly resolved; kept for reference).

This brings iOS to parity with Android "Plan B": real CoreCrypto MLS instead of
the `mls_not_implemented` stubs that force iOS onto the legacy ratchet.

---

## 1. Background — how Android does it (the model to mirror)

Android does **not** compile CoreCrypto from source. It depends on Wire's
prebuilt Maven AAR (`android/app/build.gradle.kts`):

```kotlin
implementation("com.wire:core-crypto-android:9.3.4")
```

The AAR ships the native `libcore_crypto_ffi.so` **and** the UniFFI-generated
Kotlin bindings under `com.wire.crypto`. The Kotlin bridge
(`nanb_crypto/android/src/main/kotlin/us/nanb/crypto/`) is thin glue over those
bindings. The iOS side should be the same shape: depend on Wire's **prebuilt**
iOS distribution, then glue.

> ⚠️ `ios/native_build.sh` is **stale**. It builds CoreCrypto from a Rust
> submodule (`native/core-crypto`) that was **removed** on 2026-05-15 (see
> `native/README.md`). Do not use it. Use the published package below.

## 2. Add the CoreCrypto dependency

Wire publishes CoreCrypto for Apple platforms. Pick whichever your `ios/` setup
uses (CocoaPods is what Flutter scaffolds by default):

### Option A — CocoaPods (matches the default Flutter iOS template)

In `ios/Podfile`, inside the `target 'Runner'` block:

```ruby
pod 'WireCoreCrypto', '~> 9.3'   # confirm exact pod name + version on a Mac
```

Then:

```bash
cd ios && pod install
```

### Option B — Swift Package Manager

In Xcode: *File ▸ Add Package Dependencies…* → Wire's CoreCrypto repo URL,
pin to the **9.3.x** range so the FFI surface matches the Android `9.3.4` AAR.

> **Version-match matters.** UniFFI signatures move between major versions. Keep
> iOS and Android on the same CoreCrypto major (currently 9.3.x). If you bump
> one, bump both and re-verify the API survey (Plan B Task 1).

After adding the dependency, find the module name it exposes (e.g.
`WireCoreCrypto` or `CoreCrypto`) and replace the `// import WireCoreCrypto`
TODO line at the top of each of the 5 Swift files with the real `import`.

## 3. Confirm the channel is registered

Already wired — no change needed. `ios/Runner/AppDelegate.swift` calls
`NanbCryptoChannel.register(on: engine)` inside
`didInitializeImplicitFlutterEngine`, which fires for every implicit Flutter
engine (the iOS analogue of Android's `NanbCryptoPlugin` attaching to every
`FlutterEngine`). The channel name is `nanb.crypto` on both platforms.

> iOS note: there is no separate background isolate as on Android (where
> `firebase_messaging` spawns one). `mlsInitReadOnly` exists for a future
> Notification Service Extension (decrypt-only push previews); it is harmless
> if unused. If you add an NSE target, register the channel there too.

## 4. Resolve the API-name TODOs

The dispatch logic is believed correct; the **symbol names** are guesses against
the generated Swift bindings. Every uncertain call is funnelled through a small
`@inline` shim at the bottom of `NanbCryptoChannel.swift` so each fix lives in
one place. Open the generated bindings (CocoaPods: `Pods/WireCoreCrypto/...`;
SPM: the resolved package sources) and reconcile:

| Shim / site | Kotlin reference | What to verify in Swift |
|---|---|---|
| `MlsClientHolder.defaultCiphersuite` | `Ciphersuite.MLS_128_DHKEMX25519_AES128GCM_SHA256_ED25519` | UniFFI lower-camels enum cases → likely `.mls128Dhkemx25519Aes128gcmSha256Ed25519`. |
| `convId(_:)` / `ClientId(...)` | value classes `ConversationId(bytes)` / `ClientId(bytes)` | May be structs taking `Data`, or plain `Data` typealiases. |
| `mlsKeyPackage(from:)` / `welcome(from:)` | `ByteArray.toMLSKeyPackage()` / `.toWelcome()` | Swift may expose `MlsKeyPackage(_:)` / `Welcome(_:)` inits or free funcs. |
| `keyPackageBytes(_:)` | `keyPackage.copyBytes()` | Generated `KeyPackage` may already be `Data`; if so drop the shim. |
| `welcomeBytes(_:)` / `commitBytes(_:)` | `bundle.welcome!!.copyBytes()` / `bundle.commit` | **Highest-risk.** Confirm `CommitBundle` fields: optional `welcome`, `commit: Data`. |
| `welcomeBundleId(_:)` | `welcomeBundle.id.copyBytes()` | `WelcomeBundle.id` → bytes accessor. |
| `defaultConversationConfiguration()` | `CONVERSATION_CONFIGURATION_DEFAULT` | **Not UniFFI-generated** — a Wire Kotlin helper constant. Construct the real struct by hand in Swift. |
| `defaultCustomConfiguration()` | `CUSTOM_CONFIGURATION_DEFAULT` | Same — hand-construct. |
| `cc.transaction { ctx in … }` | `client.transaction { ctx -> … }` | Confirm Swift closure form returns the closure value (`async throws`). |
| `cc.provideTransport(callbacks:)` | `c.provideTransport(CapturingMlsTransport)` | Confirm label (`callbacks:` vs `transport:`) and that `MlsTransport` is a Swift protocol with `async` methods. |
| `coreCryptoDeferredInit(path:key:entropySeed:)` | same | Confirm it returns `CoreCrypto` directly (Swift has no `.lift()`). |
| `MlsExceptions.swift` | `CoreCryptoException.Mls(MlsException.*)` | Replace the string-scan fallback with a precise `switch` on the real generated error enum once its cases are known. |

`MlsKeyPackage`, `Welcome`, `KeyPackage`, `WelcomeBundle`, `CommitBundle`,
`ConversationConfiguration`, `CustomConfiguration`, `MlsTransportResponse`,
`HistorySecret` are all referenced unqualified — they resolve once the module
is imported. If any do not exist under those names, grep the generated bindings.

## 5. Build & smoke-test

```bash
flutter clean
cd ios && pod install && cd ..
flutter run -d <ios-device-or-sim>
```

Fix compile errors (expect several from §4). Then exercise the path end-to-end:

1. Create an account on the iOS build → `mlsInit` + `mlsClientInit` succeed
   (no `mls_io` in logs).
2. 1:1 with an Android peer that has key packages → conversation should
   **auto-migrate to MLS** (watch for `mintKeyPackages` / `createGroup` /
   `addMember` / `processWelcome` channel calls succeeding).
3. Send both directions; confirm decrypt works and a fresh reinstall can't read
   prior ciphertext (forward-secrecy sanity).
4. Group create / add / remove, and self-sync across two of your own devices.

The Dart side already prefers MLS when both peers support it (the composite
bridge), so no Dart changes should be needed — iOS just stops returning
`mls_not_implemented`.

## 6. Store location parity

Android keeps the encrypted store at `filesDir/corecrypto.db`. The Swift
`MlsClientHolder.storePath()` uses iOS **Application Support**
(`<AppSupport>/corecrypto.db`) — app-private, not surfaced in the Files app,
and created on first use. The store key is derived identically on both platforms
(HKDF-SHA256 over the identity seed, `info = "nanb-corecrypto-store-v1"`,
empty salt → 32 zero bytes) so the derivation is platform-agnostic, but the
store files themselves are per-device and never shared across platforms.

## 7. Clean-up once it builds

- Delete `ios/native_build.sh` (dead from-source path) — or leave it with a
  comment pointing here; it no longer reflects how we ship CoreCrypto.
- Update `lib/core/crypto/crypto_bridge_native.dart`'s class doc (it currently
  says the iOS shim is "still Plan A stubs").
- Update `native/README.md` §"iOS counterpart" to record the chosen package +
  version, mirroring the Android AAR line.
- Drop `mls_not_implemented` from the iOS-specific handling in
  `lib/core/crypto/mls_exceptions.dart` mental model (the code still maps it for
  safety; that's fine).
```
