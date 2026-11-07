package us.nanb.crypto

import io.flutter.plugin.common.MethodChannel
import com.wire.crypto.CoreCryptoException
import com.wire.crypto.MlsException

/**
 * Maps CoreCrypto + IO exceptions to the channel error codes the Dart
 * side expects (see lib/core/crypto/mls_exceptions.dart).
 *
 * Mapping per the API survey §5:
 *   CoreCryptoException.Mls(MlsException.DuplicateMessage)    -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.WrongEpoch)          -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.StaleCommit)         -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.MessageEpochTooOld)  -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.SelfCommitIgnored)   -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.MessageRejected)     -> mls_decrypt_failed
 *   CoreCryptoException.Mls(MlsException.ConversationAlreadyExists) -> mls_invalid_argument
 *   CoreCryptoException.Mls(MlsException.OrphanWelcome)       -> mls_invalid_argument
 *   CoreCryptoException.Mls(MlsException.Other) w/ missing-convo msg -> mls_unknown_group
 *   CoreCryptoException.Mls(MlsException.Other)               -> mls_unknown
 *   CoreCryptoException.Other                                  -> mls_io
 *   CoreCryptoException.TransactionFailed                      -> mls_io
 *   IllegalArgumentException                                   -> mls_invalid_argument
 *   <anything else>                                            -> mls_io
 */
internal fun MethodChannel.Result.errorFor(e: Throwable) {
    val (code, msg) = when (e) {
        is CoreCryptoException.Mls -> {
            when (val mls = e.mlsError) {
                is MlsException.DuplicateMessage,
                is MlsException.WrongEpoch,
                is MlsException.StaleCommit,
                is MlsException.MessageEpochTooOld,
                is MlsException.SelfCommitIgnored,
                is MlsException.MessageRejected -> "mls_decrypt_failed" to (mls.message ?: mls.javaClass.simpleName)
                is MlsException.OrphanWelcome -> "mls_orphan_welcome" to (mls.message ?: mls.javaClass.simpleName)
                is MlsException.ConversationAlreadyExists -> "mls_invalid_argument" to (mls.message ?: mls.javaClass.simpleName)
                is MlsException.Other -> {
                    val mlsMsg = mls.msg
                    // CoreCrypto reports a missing conversation/group through the
                    // free-text MlsException.Other message, and the phrasing varies
                    // by version: "not found", "Couldn't find conversation", and
                    // "unknown conversation" have all been observed. Route any of
                    // them to mls_unknown_group — the code the Dart heal path
                    // (reconcileMlsConversations / re-establishment) keys on. A plain
                    // contains("not found") check missed "Couldn't find conversation",
                    // so the auto-heal never fired and the 1:1 stayed permanently
                    // unsendable (every send failed at the MLS encrypt step).
                    val lower = mlsMsg.lowercase()
                    if (lower.contains("not found") ||
                        lower.contains("find conversation") ||
                        lower.contains("unknown conversation"))
                        "mls_unknown_group" to mlsMsg
                    else
                        "mls_unknown" to mlsMsg
                }
                else -> "mls_unknown" to (mls.message ?: mls.javaClass.simpleName)
            }
        }
        is CoreCryptoException.Other -> "mls_io" to e.msg
        is CoreCryptoException.TransactionFailed -> "mls_io" to e.error
        is IllegalArgumentException -> "mls_invalid_argument" to (e.message ?: "invalid argument")
        else -> "mls_io" to (e.message ?: e.javaClass.simpleName)
    }
    error(code, msg, null)
}
