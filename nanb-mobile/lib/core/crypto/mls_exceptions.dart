/// Typed exceptions raised by `CryptoBridgeNative` after mapping the
/// `PlatformException.code` returned from the native MLS shim.
///
/// Mapping table (kept in lockstep with the Kotlin/Swift handlers):
///   mls_not_implemented   -> MlsNotImplementedException
///   mls_unknown_group     -> MlsUnknownGroupException
///   mls_decrypt_failed    -> MlsDecryptException
///   mls_io                -> MlsIoException
///   mls_invalid_argument  -> MlsArgumentException
///   mls_orphan_welcome    -> MlsOrphanWelcomeException
///   anything else        -> MlsUnknownException (with original code)
class MlsException implements Exception {
  const MlsException(this.message);
  final String message;

  @override
  String toString() => 'MlsException: $message';
}

/// The native handler isn't wired on this platform — Android is real
/// (Plan B); the iOS shim still returns this for every MLS method.
class MlsNotImplementedException extends MlsException {
  const MlsNotImplementedException(super.message);
  @override
  String toString() => 'MlsNotImplementedException: $message';
}

/// Caller asked CoreCrypto about a group_id it doesn't know.
class MlsUnknownGroupException extends MlsException {
  const MlsUnknownGroupException(super.message);
  @override
  String toString() => 'MlsUnknownGroupException: $message';
}

/// AEAD verify or MLS sanity check failed during decrypt.
class MlsDecryptException extends MlsException {
  const MlsDecryptException(super.message);
  @override
  String toString() => 'MlsDecryptException: $message';
}

/// Underlying SQLite or filesystem failure inside CoreCrypto's store.
class MlsIoException extends MlsException {
  const MlsIoException(super.message);
  @override
  String toString() => 'MlsIoException: $message';
}

/// Bad input from Dart — empty bytes where bytes required, etc.
class MlsArgumentException extends MlsException {
  const MlsArgumentException(super.message);
  @override
  String toString() => 'MlsArgumentException: $message';
}

/// A Welcome this device can't open: its key package's private half is gone, so
/// no retry can ever succeed. Nothing was changed by the attempt, so a group held
/// under that id is still intact and must be kept.
class MlsOrphanWelcomeException extends MlsArgumentException {
  const MlsOrphanWelcomeException(super.message);
}

/// Fallback for unrecognised native error codes.
class MlsUnknownException extends MlsException {
  const MlsUnknownException(this.code, super.message);
  final String code;
  @override
  String toString() => 'MlsUnknownException($code): $message';
}
