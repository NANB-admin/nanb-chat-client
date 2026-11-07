package us.nanb.crypto

import android.content.Context
import com.wire.crypto.Ciphersuite
import com.wire.crypto.ClientId
import com.wire.crypto.CONVERSATION_CONFIGURATION_DEFAULT
import com.wire.crypto.CUSTOM_CONFIGURATION_DEFAULT
import com.wire.crypto.ConversationId
import com.wire.crypto.CoreCryptoException
import com.wire.crypto.CredentialType
import com.wire.crypto.MlsException
import com.wire.crypto.toMLSKeyPackage
import com.wire.crypto.toWelcome
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Method channel handler for `nanb.crypto`. Plan B wires all MLS operations
 * to real CoreCrypto calls via MlsClientHolder.
 *
 * mlsInit: receives a 32-byte seed from Dart, opens the CoreCrypto SQLite
 *   store at filesDir/corecrypto.db with a key derived from the seed.
 * mlsWipe: closes the store and deletes the on-disk file.
 * mintKeyPackages: calls ctx.clientKeypackages(ciphersuite, credentialType,
 *   amount) inside a CoreCrypto transaction and returns List<ByteArray>.
 * createGroup: calls ctx.createConversation(conversationId, credentialType,
 *   config) — groupId == conversationId per spec §7.3.
 * addMember: calls ctx.addClientsToConversation(groupId, listOf(kp)); the
 *   CommitBundle is captured by CapturingMlsTransport; Welcome bytes are
 *   extracted from the bundle and returned to Dart.
 * processWelcome: calls ctx.processWelcomeMessage(welcome, customConfig);
 *   returns the new groupId string derived from WelcomeBundle.id.
 *
 * All method handler bodies are wrapped in try/catch and route exceptions
 * through the MlsExceptions.errorFor helper so Dart always gets a typed
 * PlatformException with a channel error code.
 *
 * Coroutine scope: CoreCrypto calls involve disk I/O so we dispatch them on
 * Dispatchers.IO. SupervisorJob keeps sibling coroutines alive if one fails.
 */
class NanbCryptoChannel(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    companion object {
        /** Default ciphersuite per survey §4.3 — RFC 9420 MLS_128 baseline. */
        private val DEFAULT_CIPHERSUITE =
            Ciphersuite.MLS_128_DHKEMX25519_AES128GCM_SHA256_ED25519
    }

    // Internal (not private): NanbCryptoPlugin binds this as the
    // MethodChannel handler for every engine it attaches to — including
    // the FCM background isolate's engine.
    internal fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "mlsInit" -> {
                try {
                    val seed = call.argument<ByteArray>("seed")
                        ?: return result.errorFor(
                            IllegalArgumentException("missing seed arg")
                        )
                    if (seed.size != 32) {
                        return result.errorFor(
                            IllegalArgumentException("seed must be 32 bytes, got ${seed.size}")
                        )
                    }
                    MlsClientHolder.initIfNeeded(context, seed)
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "mlsClientInit" -> {
                try {
                    val clientId = call.argument<String>("clientId")
                        ?: return result.errorFor(
                            IllegalArgumentException("missing clientId arg")
                        )
                    if (clientId.isEmpty()) {
                        return result.errorFor(
                            IllegalArgumentException("clientId must be non-empty")
                        )
                    }
                    MlsClientHolder.ensureMlsClient(clientId.encodeToByteArray())
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "mlsInitReadOnly" -> {
                try {
                    val seed = call.argument<ByteArray>("seed")
                        ?: return result.errorFor(
                            IllegalArgumentException("missing seed arg")
                        )
                    if (seed.size != 32) {
                        return result.errorFor(
                            IllegalArgumentException("seed must be 32 bytes, got ${seed.size}")
                        )
                    }
                    MlsClientHolder.initReadOnly(context, seed)
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "mlsWipe" -> {
                try {
                    MlsClientHolder.wipe(context)
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "mlsConsumeStoreReset" -> {
                try {
                    result.success(MlsClientHolder.consumeStoreWasReset())
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "mintKeyPackages" -> scope.launch {
                try {
                    val count = call.argument<Int>("count") ?: 100
                    if (count < 1 || count > 500) {
                        return@launch result.errorFor(
                            IllegalArgumentException("count out of range: $count")
                        )
                    }
                    val client = MlsClientHolder.get()
                    // ctx.clientKeypackages signature per survey §4.3:
                    //   clientKeypackages(ciphersuite, credentialType, amount: Int)
                    // Returns List<KeyPackage>; each .copyBytes() gives raw ByteArray.
                    val packages: List<ByteArray> = client.transaction { ctx ->
                        val kps = ctx.clientKeypackages(
                            ciphersuite = DEFAULT_CIPHERSUITE,
                            credentialType = CredentialType.BASIC,
                            amountRequested = count.toUInt(),
                        )
                        kps.map { it.copyBytes() }
                    }
                    // Flutter StandardMessageCodec encodes List<ByteArray> as
                    // List of Uint8List on the Dart side — matching CryptoBridgeNative.
                    result.success(packages)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "createGroup" -> scope.launch {
                try {
                    val conversationId = call.argument<String>("conversationId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing conversationId")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.createConversation signature per survey §4.4:
                    //   createConversation(conversationId, credentialType, config): Unit
                    // groupId == conversationId per spec §7.3 invariant.
                    client.transaction { ctx ->
                        ctx.createConversation(
                            conversationId = ConversationId(conversationId.encodeToByteArray()),
                            creatorCredentialType = CredentialType.BASIC,
                            config = CONVERSATION_CONFIGURATION_DEFAULT,
                        )
                    }
                    result.success(conversationId)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "addMember" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val peerKeyPackage = call.argument<ByteArray>("peerKeyPackage")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing peerKeyPackage")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.addClientsToConversation signature per survey §4.5:
                    //   addClientsToConversation(conversationId, keyPackages): List<String>
                    // Returns failed client IDs — ignored for Plan B (1:1, expect empty).
                    // The CommitBundle (containing Welcome bytes for the peer) is captured
                    // by CapturingMlsTransport.sendCommitBundle during the transaction.
                    // toMLSKeyPackage is a ByteArray extension fun on MlsModelKt.
                    client.transaction { ctx ->
                        ctx.addClientsToConversation(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            keyPackages = listOf(peerKeyPackage.toMLSKeyPackage()),
                        )
                    }
                    // Retrieve the CommitBundle captured during the transaction.
                    // Welcome.copyBytes() confirmed via javap: returns ByteArray.
                    val bundle = CapturingMlsTransport.take()
                        ?: return@launch result.errorFor(
                            IllegalStateException(
                                "addClientsToConversation did not dispatch a CommitBundle " +
                                    "for group $groupId — CapturingMlsTransport.take() returned null"
                            )
                        )
                    val welcomeBytes: ByteArray = bundle.welcome!!.copyBytes()
                    val commitBytes: ByteArray = bundle.commit
                    result.success(mapOf(
                        "welcome" to welcomeBytes,
                        "commit" to commitBytes,
                    ))
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "addMembers" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val peerKeyPackages = call.argument<List<ByteArray>>("peerKeyPackages")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing peerKeyPackages")
                        )
                    if (peerKeyPackages.isEmpty()) {
                        return@launch result.errorFor(
                            IllegalArgumentException("peerKeyPackages must not be empty")
                        )
                    }
                    val client = MlsClientHolder.get()
                    // One addClientsToConversation call adding ALL members
                    // produces a SINGLE CommitBundle: one epoch advance and one
                    // Welcome covering every added member (each processes the
                    // same Welcome and finds its own leaf). This is the only
                    // correct way to seed a group with N>1 members — adding
                    // one at a time leaves earlier members an epoch behind.
                    client.transaction { ctx ->
                        ctx.addClientsToConversation(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            keyPackages = peerKeyPackages.map { it.toMLSKeyPackage() },
                        )
                    }
                    val bundle = CapturingMlsTransport.take()
                        ?: return@launch result.errorFor(
                            IllegalStateException(
                                "addClientsToConversation did not dispatch a CommitBundle " +
                                    "for group $groupId — CapturingMlsTransport.take() returned null"
                            )
                        )
                    val welcomeBytes: ByteArray = bundle.welcome!!.copyBytes()
                    val commitBytes: ByteArray = bundle.commit
                    result.success(mapOf(
                        "welcome" to welcomeBytes,
                        "commit" to commitBytes,
                    ))
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "removeMember" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val targetDeviceId = call.argument<String>("targetDeviceId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing targetDeviceId")
                        )
                    val client = MlsClientHolder.get()
                    // CoreCrypto v9 removeClientsFromConversation:
                    //   removeClientsFromConversation(conversationId, clients)
                    // ClientId is constructed from deviceId UTF-8 bytes per survey §6.
                    // The CommitBundle (Commit to fan out to remaining members + the
                    // removed device) is captured by CapturingMlsTransport during the
                    // transaction — same pattern as addMember.
                    client.transaction { ctx ->
                        ctx.removeClientsFromConversation(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            clients = listOf(ClientId(targetDeviceId.encodeToByteArray())),
                        )
                    }
                    // Retrieve the CommitBundle captured during the transaction.
                    // bundle.commit is ByteArray per CapturingMlsTransport javap comment.
                    // There is no Welcome on remove (unlike addMember).
                    val bundle = CapturingMlsTransport.take()
                        ?: return@launch result.errorFor(
                            IllegalStateException(
                                "removeClientsFromConversation did not dispatch a CommitBundle " +
                                    "for group $groupId — CapturingMlsTransport.take() returned null"
                            )
                        )
                    result.success(bundle.commit)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "processWelcome" -> scope.launch {
                try {
                    val welcomeBytes = call.argument<ByteArray>("welcomeBytes")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing welcomeBytes")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.processWelcomeMessage signature per survey §4.6:
                    //   processWelcomeMessage(welcome, customConfiguration): WelcomeBundle
                    // WelcomeBundle.id: ConversationId; ConversationId.copyBytes(): ByteArray.
                    // toWelcome is a ByteArray extension fun on MlsModelKt.
                    val welcomeBundle = client.transaction { ctx ->
                        ctx.processWelcomeMessage(
                            welcomeMessage = welcomeBytes.toWelcome(),
                            customConfiguration = CUSTOM_CONFIGURATION_DEFAULT,
                        )
                    }
                    val groupId = welcomeBundle.id.copyBytes().decodeToString()
                    result.success(groupId)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "encrypt" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val plaintext = call.argument<ByteArray>("plaintext")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing plaintext")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.encryptMessage signature per survey §4.9:
                    //   encryptMessage(conversationId: ConversationId, message: ByteArray): ByteArray
                    val ciphertext: ByteArray = client.transaction { ctx ->
                        ctx.encryptMessage(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            message = plaintext,
                        )
                    }
                    result.success(ciphertext)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "decrypt" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val ciphertext = call.argument<ByteArray>("ciphertext")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing ciphertext")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.decryptMessage signature per survey §4.10:
                    //   decryptMessage(conversationId: ConversationId, payload: ByteArray): DecryptedMessage
                    // DecryptedMessage.message is ByteArray? — null for commits/proposals.
                    // Convert null → ByteArray(0) so the channel never returns null;
                    // Dart side handles empty list as a legitimate handshake result.
                    val maybePlaintext: ByteArray? = client.transaction { ctx ->
                        val decrypted = ctx.decryptMessage(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            payload = ciphertext,
                        )
                        decrypted.message
                    }
                    result.success(maybePlaintext ?: ByteArray(0))
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "decryptAndInspect" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val ciphertext = call.argument<ByteArray>("ciphertext")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing ciphertext")
                        )
                    val client = MlsClientHolder.get()
                    // ctx.decryptMessage returns DecryptedMessage{message: ByteArray?, isActive: Boolean, ...}
                    // message is null for commits/proposals; non-null for application messages.
                    // isActive is false when this Commit removed us from the group (survey §4.10).
                    val decrypted = client.transaction { ctx ->
                        ctx.decryptMessage(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            payload = ciphertext,
                        )
                    }
                    val maybePlaintext: ByteArray? = decrypted.message
                    // The MLS-authenticated sender. CoreCrypto surfaces the sender's
                    // MLS client id on the DecryptedMessage; we init each client with
                    // clientId = deviceId (see mlsClientInit), so this decodes straight
                    // back to the sender's device id — cryptographically authenticated by
                    // MLS, unlike the server-assigned transport sender_device_id. Null for
                    // commits/proposals (no application sender). Sealed-sender Phase 0:
                    // the receive path attributes the sender from THIS, not the transport.
                    val senderClientId: String? =
                        decrypted.senderClientId?.copyBytes()?.decodeToString()
                    // Use isActive to detect self-removal: false means we were removed.
                    // When removed, conversationEpoch would throw (conversation gone),
                    // so we skip the epoch query in that case.
                    val selfRemoved = !decrypted.isActive
                    val newEpoch: Long? = if (selfRemoved) {
                        null
                    } else {
                        // survey §4.8: conversationEpoch is read-only, no transaction required.
                        try {
                            client.conversationEpoch(
                                conversationId = ConversationId(groupId.encodeToByteArray()),
                            ).toLong()
                        } catch (_: Throwable) {
                            // Conversation gone despite isActive=true — treat as self-removed.
                            null
                        }
                    }
                    val payload = mapOf<String, Any?>(
                        "plaintext" to maybePlaintext,
                        "selfRemoved" to selfRemoved,
                        "newEpoch" to newEpoch,
                        "senderClientId" to senderClientId,
                    )
                    result.success(payload)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "processCommit" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val commitBytes = call.argument<ByteArray>("commitBytes")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing commitBytes")
                        )
                    val client = MlsClientHolder.get()
                    // survey §4.7: no dedicated processCommit; commits, proposals, and app
                    // messages all route through decryptMessage. message == null for commits.
                    client.transaction { ctx ->
                        ctx.decryptMessage(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                            payload = commitBytes,
                        )
                        // discard result — caller does not need the plaintext
                    }
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "currentEpoch" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val client = MlsClientHolder.get()
                    // survey §4.8: conversationEpoch is available directly on
                    // CoreCryptoClient — no transaction required (read-only query).
                    val epoch: ULong = client.conversationEpoch(
                        conversationId = ConversationId(groupId.encodeToByteArray()),
                    )
                    // ULong cannot cross the Flutter channel; cast to Long.
                    // Epochs > Long.MAX_VALUE would require a redesign anyway.
                    result.success(epoch.toLong())
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "groupMembers" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val client = MlsClientHolder.get()
                    // clientId = deviceId (see mlsClientInit), so each decodes to
                    // the device id. Read-only, like conversationEpoch above.
                    val members = client.getClientIds(
                        ConversationId(groupId.encodeToByteArray()),
                    )
                    result.success(members.map { it.copyBytes().decodeToString() })
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "replaceGroup" -> scope.launch {
                try {
                    val localGroupId = call.argument<String>("localGroupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing localGroupId")
                        )
                    val foreignWelcome = call.argument<ByteArray>("foreignWelcome")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing foreignWelcome")
                        )
                    val client = MlsClientHolder.get()
                    // Simultaneous-migration tiebreaker (spec §9.3) + orphan
                    // adoption: wipe the local group, then process the
                    // incoming Welcome to re-init from the peer's group.
                    //
                    // DELIBERATELY two transactions. Running both ops in ONE
                    // transaction looked atomic but the wipe was applied at
                    // COMMIT over the group processWelcomeMessage had just
                    // created under the same id — replaceGroup "succeeded"
                    // yet the group was gone ("Couldn't find conversation"
                    // on every subsequent decrypt; found live 2026-06-07).
                    // Non-atomicity is acceptable: both call sites are
                    // replacing a group that is already dead/orphaned, so a
                    // failure between the transactions leaves us no worse
                    // (no group) and the next Welcome retry can still init.
                    // wipeConversation signature (javap confirmed):
                    //   wipeConversation(ConversationId, Continuation): Unit
                    //
                    // BEST-EFFORT: there may be nothing to replace. CoreCrypto
                    // drops the conversation when a Commit removes us from the
                    // group, so a re-add Welcome arrives with no local group
                    // and wipeConversation throws "Couldn't find conversation".
                    // Letting that abort replaceGroup meant a re-invite could
                    // never be adopted — the Welcome failed identically on
                    // every catchup, forever, leaving the user stuck on "You
                    // were removed from this group". Nothing to wipe is exactly
                    // the state processWelcomeMessage below wants.
                    //
                    // OPEN THE WELCOME FIRST. CoreCrypto decrypts it before it checks
                    // for an existing group (crypto/src/mls/conversation/welcome.rs),
                    // so "already exists" proves this Welcome is good and only then
                    // do we wipe. Wiping first destroyed a healthy group whenever the
                    // Welcome turned out to be built from a dead key package.
                    suspend fun join(): ByteArray = client.transaction { ctx ->
                        val welcomeBundle = ctx.processWelcomeMessage(
                            welcomeMessage = foreignWelcome.toWelcome(),
                            customConfiguration = CUSTOM_CONFIGURATION_DEFAULT,
                        )
                        welcomeBundle.id.copyBytes()
                    }
                    val newGroupId: ByteArray = try {
                        join()
                    } catch (e: Throwable) {
                        val alreadyExists = (e as? CoreCryptoException.Mls)?.mlsError is
                            MlsException.ConversationAlreadyExists ||
                            e.toString().contains("ConversationAlreadyExists")
                        if (!alreadyExists) throw e
                        try {
                            client.transaction { ctx ->
                                ctx.wipeConversation(
                                    conversationId = ConversationId(localGroupId.encodeToByteArray()),
                                )
                            }
                        } catch (_: Throwable) { /* no local group to replace */ }
                        join()
                    }
                    result.success(String(newGroupId, Charsets.UTF_8))
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            "wipeGroup" -> scope.launch {
                try {
                    val groupId = call.argument<String>("groupId")
                        ?: return@launch result.errorFor(
                            IllegalArgumentException("missing groupId")
                        )
                    val client = MlsClientHolder.get()
                    // MlsMigrator cleanup: drop a half-created group left by
                    // a failed outbound migration so a retry (or the peer's
                    // Welcome for the same conversation id) can succeed.
                    client.transaction { ctx ->
                        ctx.wipeConversation(
                            conversationId = ConversationId(groupId.encodeToByteArray()),
                        )
                    }
                    result.success(null)
                } catch (e: Throwable) {
                    result.errorFor(e)
                }
            }
            else -> result.notImplemented()
        }
    }
}
