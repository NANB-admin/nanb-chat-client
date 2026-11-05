import 'mls_exceptions.dart';

/// Maps errors thrown by the browser MLS bridge (`web/nanb_mls.js`) onto the
/// same typed [MlsException]s `CryptoBridgeNative` produces.
///
/// The JS side rejects with an Error whose message is
/// `nanb_mls_code=<code>;<message>`. Whatever wrapper the JS-interop layer adds
/// around it, the marker survives in the stringified error, so this works on
/// plain text and is VM-testable.
class MlsErrorMapper {
  const MlsErrorMapper._();

  static final RegExp _marker = RegExp(r'nanb_mls_code=([a-z_]+);([\s\S]*)');

  static MlsException fromErrorText(String text) {
    final match = _marker.firstMatch(text);
    if (match == null) return MlsIoException(text);
    return fromCode(match.group(1)!, match.group(2)!.trim());
  }

  static MlsException fromCode(String code, String message) {
    switch (code) {
      case 'mls_not_implemented':
        return MlsNotImplementedException(message);
      case 'mls_unknown_group':
        return MlsUnknownGroupException(message);
      case 'mls_decrypt_failed':
        return MlsDecryptException(message);
      case 'mls_io':
        return MlsIoException(message);
      case 'mls_invalid_argument':
        return MlsArgumentException(message);
      default:
        return MlsUnknownException(code, message);
    }
  }
}
