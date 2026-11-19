package nl.haltewekker.friends

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The standard pieces the Friends formats are built from (spec "As built (0.25)"), from Bouncy Castle's lightweight
 * API (pure Java: Android has Ed25519 only from API 33 and X25519 from 31, the app starts at 26):
 * Ed25519 (RFC 8032), X25519 (RFC 7748), HKDF-SHA256 (RFC 5869), ChaCha20-Poly1305 (RFC 8439: 12-byte nonce,
 * 16-byte tag), SHA-256.
 */
object FriendCrypto {
    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val d = MessageDigest.getInstance("SHA-256")
        for (p in parts) d.update(p)
        return d.digest()
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        val g = HKDFBytesGenerator(SHA256Digest())
        g.init(HKDFParameters(ikm, salt, info))
        return ByteArray(length).also { g.generateBytes(it, 0, length) }
    }

    // MARK: Ed25519

    /** The public key (32 bytes) of an Ed25519 secret (the RFC 8032 32-byte seed). */
    fun edPublic(secret: ByteArray): ByteArray = Ed25519PrivateKeyParameters(secret, 0).generatePublicKey().encoded

    /** A deterministic Ed25519 signature (64 bytes). */
    fun sign(secret: ByteArray, message: ByteArray): ByteArray {
        val s = Ed25519Signer()
        s.init(true, Ed25519PrivateKeyParameters(secret, 0))
        s.update(message, 0, message.size)
        return s.generateSignature()
    }

    fun verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        return try {
            val v = Ed25519Signer()
            v.init(false, Ed25519PublicKeyParameters(publicKey, 0))
            v.update(message, 0, message.size)
            v.verifySignature(signature)
        } catch (_: Exception) { false }
    }

    // MARK: X25519

    /** The public key of an X25519 private scalar (clamped as RFC 7748 does). */
    fun xPublic(priv: ByteArray): ByteArray = X25519PrivateKeyParameters(priv, 0).generatePublicKey().encoded

    /** The shared secret, or null for a key that gives none (all zeros: a low-order point). */
    fun agree(priv: ByteArray, theirPublic: ByteArray): ByteArray? {
        if (theirPublic.size != 32) return null
        return try {
            val out = ByteArray(32)
            X25519PrivateKeyParameters(priv, 0).generateSecret(X25519PublicKeyParameters(theirPublic, 0), out, 0)
            out
        } catch (_: Exception) { null }
    }

    // MARK: ChaCha20-Poly1305

    /** ciphertext ‖ tag (16). */
    fun seal(key: ByteArray, nonce: ByteArray, plain: ByteArray, aad: ByteArray): ByteArray {
        val c = ChaCha20Poly1305()
        c.init(true, AEADParameters(KeyParameter(key), 128, nonce, aad))
        val out = ByteArray(c.getOutputSize(plain.size))
        val n = c.processBytes(plain, 0, plain.size, out, 0)
        c.doFinal(out, n)
        return out
    }

    /** The plain text, or null: the key, nonce, AAD or tag don't fit. */
    fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray? {
        if (sealed.size < 16 || nonce.size != 12) return null
        return try {
            val c = ChaCha20Poly1305()
            c.init(false, AEADParameters(KeyParameter(key), 128, nonce, aad))
            val out = ByteArray(c.getOutputSize(sealed.size))
            val n = c.processBytes(sealed, 0, sealed.size, out, 0)
            val m = c.doFinal(out, n)
            out.copyOf(n + m)
        } catch (_: Exception) { null }
    }
}
