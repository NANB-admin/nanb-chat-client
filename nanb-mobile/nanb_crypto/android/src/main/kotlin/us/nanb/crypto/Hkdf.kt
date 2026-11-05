package us.nanb.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * RFC 5869 HKDF using HMAC-SHA256. Self-contained — no BouncyCastle dep.
 * Used only for deriving CoreCrypto's store-encryption key from the
 * user's identity seed.
 */
internal object Hkdf {
    private const val HMAC_SHA256 = "HmacSHA256"

    fun derive(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32) { "length out of range: $length" }
        val prk = extract(ikm = ikm, salt = if (salt.isEmpty()) ByteArray(32) else salt)
        return expand(prk = prk, info = info, length = length)
    }

    private fun extract(ikm: ByteArray, salt: ByteArray): ByteArray {
        val mac = Mac.getInstance(HMAC_SHA256)
        mac.init(SecretKeySpec(salt, HMAC_SHA256))
        return mac.doFinal(ikm)
    }

    private fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance(HMAC_SHA256)
        mac.init(SecretKeySpec(prk, HMAC_SHA256))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter: Byte = 1
        while (pos < length) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(counter)
            t = mac.doFinal()
            val toCopy = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, toCopy)
            pos += toCopy
            counter++
        }
        return out
    }
}
