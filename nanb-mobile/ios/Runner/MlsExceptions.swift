// Active as of the iOS MLS integration (docs/ios-mls-build.md). Maps CoreCrypto +
// local errors to the channel error codes the Dart side expects.
//
// The generated Swift error shape IS now known from a live device:
//   Mls(mlsError: WireCoreCryptoUniffi.MlsError.Other(msg: "…"))
// so the string-scan below could be replaced with a precise switch on
// `MlsError` — worth doing next time this file is open in Xcode, where the full
// case list can actually be checked. Until then the scan is authoritative, and
// its needles MUST stay in lockstep with Android's (MlsExceptions.kt): a needle
// that only Android has is a heal path that only Android gets.
import Flutter
import Foundation

/// Maps CoreCrypto + local errors to the channel error codes the Dart side
/// expects (see lib/core/crypto/mls_exceptions.dart). Mirror of the Android
/// `MethodChannel.Result.errorFor` (nanb_crypto/.../MlsExceptions.kt).
///
/// The Kotlin matches on `CoreCryptoException.Mls(MlsException.<case>)`. The
/// UniFFI-generated SWIFT error type and case names differ and are NOT known
/// from Windows — so the precise pattern-match below is the SECOND most likely
/// place (after CommitBundle field names) to need an Xcode fix-up. To keep the
/// behaviour correct even before those names are pinned down, we ALSO fall back
/// to a string-scan of the error description for the same signals the Kotlin
/// keys off (`not found`, `duplicate`, `epoch`, `stale`, `orphan`, …).
///
/// Mapping intent (must stay aligned with Android):
///   duplicate / wrong-epoch / stale / too-old / self-commit / rejected
///                                              -> mls_decrypt_failed
///   conversation-already-exists / orphan-welcome -> mls_invalid_argument
///   "not found"                                   -> mls_unknown_group
///   other MLS error                               -> mls_unknown
///   IO / transaction failure                      -> mls_io
///   invalid argument                              -> mls_invalid_argument
extension FlutterError {
  static func from(_ error: Error) -> FlutterError {
    // 1) Local, non-CoreCrypto errors.
    if let nanb = error as? NanbMlsError {
      switch nanb {
      case .notInitialized:
        return FlutterError(code: "mls_io",
                            message: "MlsClientHolder not initialized — call mlsInit first",
                            details: nil)
      case .missingArgument(let m), .invalidArgument(let m):
        return FlutterError(code: "mls_invalid_argument", message: m, details: nil)
      case .noCommitBundle(let m), .storeOpenFailed(let m):
        return FlutterError(code: "mls_io", message: m, details: nil)
      }
    }

    // 2) CoreCrypto errors. Once the generated Swift error enum is known,
    //    replace this string-scan with a precise `switch` on the real cases
    //    (e.g. `case .mls(.duplicateMessage)`). The scan below is a faithful
    //    stand-in that keys off the SAME signals the Kotlin switch does.
    let desc = "\(error)".lowercased()

    func has(_ needles: String...) -> Bool { needles.contains { desc.contains($0) } }

    let code: String
    // CoreCrypto reports a missing conversation through the FREE-TEXT
    // `MlsError.Other(msg:)` payload, and the phrasing varies by version.
    // Observed live on an iPhone (TestFlight 1.0.0+12, 2026-07-28):
    //   Mls(mlsError: WireCoreCryptoUniffi.MlsError.Other(
    //       msg: "Couldn't find conversation"))
    // which matches NONE of "not found" / "unknown group" /
    // "no such conversation", fell through every branch below, and landed on
    // the default `mls_io`.
    //
    // That is not cosmetic. `mls_io` -> MlsIoException, and every Dart heal
    // path keys on MlsUnknownGroupException instead:
    //   - reconcileMlsConversations explicitly LEAVES I/O errors alone ("should
    //     not incorrectly flag healthy conversations"), so it never flags
    //     needsReestablishment and never kicks off re-establishment;
    //   - MlsReceiver._isPermanentWelcomeFailure never treats the Welcome as
    //     permanent, so a re-add Welcome retries and fails forever.
    // Net effect on iOS: a 1:1 whose group is missing stays unsendable, with
    // the raw exception surfaced to the user, and NOTHING repairs it.
    //
    // Android hit exactly this and fixed it (MlsExceptions.kt) by matching
    // "find conversation" and "unknown conversation" too; this mirror was never
    // updated. Keep the two lists in lockstep.
    if has("not found", "find conversation", "unknown conversation",
           "unknown group", "no such conversation") {
      code = "mls_unknown_group"
    } else if has("duplicate", "wrong epoch", "stale commit",
                  "epoch too old", "self commit", "self-commit",
                  "message rejected", "messagerejected") {
      code = "mls_decrypt_failed"
    } else if has("already exists", "orphan welcome", "orphanwelcome") {
      code = "mls_invalid_argument"
    } else if has("invalid argument", "illegalargument") {
      code = "mls_invalid_argument"
    } else if has("transaction", "io error", "ioerror", "database", "store") {
      code = "mls_io"
    } else {
      // Default differs from Kotlin's two tails (mls_unknown vs mls_io) only
      // in the label; both map to a generic Dart MlsUnknownException-ish path.
      code = "mls_io"
    }
    return FlutterError(code: code, message: "\(error)", details: nil)
  }
}
