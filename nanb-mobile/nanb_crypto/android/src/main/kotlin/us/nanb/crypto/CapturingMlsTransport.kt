package us.nanb.crypto

import com.wire.crypto.CommitBundle
import com.wire.crypto.HistorySecret
import com.wire.crypto.MlsTransport
import com.wire.crypto.MlsTransportResponse
import java.util.concurrent.atomic.AtomicReference

/**
 * Captures CommitBundles dispatched by CoreCrypto so the channel-side
 * addMember handler can return the Welcome bytes synchronously.
 *
 * CoreCrypto v9 dispatches Commits via this callback during
 * addClientsToConversation. The callback fires inside the transaction,
 * before addClientsToConversation returns to our coroutine. We store the
 * bundle in an AtomicReference so the addMember arm can read it
 * immediately after the transaction completes.
 *
 * CommitBundle fields confirmed via javap against core-crypto-android-9.3.4.aar:
 *   welcome: Welcome?       - getWelcome() / Welcome.copyBytes() -> ByteArray
 *   commit: byte[]
 *   groupInfo: GroupInfoBundle
 *   encryptedMessage: byte[]
 * Note: CommitBundle has NO conversationId field. The last-write AtomicReference
 * design is correct for Plan B (one addMember at a time per coroutine scope).
 *
 * Plan C will replace this with a real implementation that ALSO posts
 * the commit bundle to the server via POST /messages.
 */
internal object CapturingMlsTransport : MlsTransport {
    private val lastBundle = AtomicReference<CommitBundle?>(null)

    override suspend fun sendCommitBundle(commitBundle: CommitBundle): MlsTransportResponse {
        lastBundle.set(commitBundle)
        return MlsTransportResponse.Success
    }

    override suspend fun sendMessage(mlsMessage: ByteArray): MlsTransportResponse {
        // No-op: application messages are sent through our own POST /messages
        // pipeline on the Dart side, not via this transport.
        return MlsTransportResponse.Success
    }

    override suspend fun prepareForTransport(historySecret: HistorySecret): ByteArray {
        return ByteArray(0)
    }

    /**
     * Takes the most recently captured CommitBundle and clears the slot.
     * Returns null if sendCommitBundle was not called (e.g., CoreCrypto
     * optimised away the commit - treat as an error at the call site).
     */
    fun take(): CommitBundle? = lastBundle.getAndSet(null)
}
