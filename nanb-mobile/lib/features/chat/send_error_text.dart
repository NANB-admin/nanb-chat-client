import '../../core/crypto/mls_exceptions.dart';
import '../../core/models/api_error.dart';
import '../../core/network/ws_client.dart';

/// Turns a failed send's exception into one sentence a user can act on.
///
/// The thread used to show `e.toString()` verbatim, so a lost MLS group
/// surfaced as "MlsUnknownGroupException: Mls(mlsError: WireCoreCryptoUniffi…)"
/// — alarming and meaningless. The failed bubble already carries the Retry
/// affordance; this text only has to say what went wrong and what to do.
String sendErrorText(Object error, {bool isGroup = false}) {
  if (error is MlsUnknownGroupException) {
    return isGroup
        ? "This device lost its keys for this group. Ask a member to remove "
            "and re-add you."
        : "Couldn't send — repairing this chat's encryption. Tap the message "
            "to retry.";
  }
  if (error is MlsException) {
    return "Couldn't encrypt this message. Tap it to retry.";
  }
  if (error is WsSendException && error.code == 'account_not_found') {
    return "This contact's device is no longer available.";
  }
  if (error is ApiError && error.code == 'account_not_found') {
    return "This contact's device is no longer available.";
  }
  if (error is ApiError && error.statusCode == 429) {
    return 'Sending too fast — wait a moment, then tap the message to retry.';
  }
  return "Couldn't send. Check your connection and tap the message to retry.";
}
