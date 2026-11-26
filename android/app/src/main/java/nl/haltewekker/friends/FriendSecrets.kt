package nl.haltewekker.friends

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The account's secret (the 16-byte seed) and this phone's device id, as the iOS Keychain keeps them (this device
 * only, never in a backup): each is locked with an AES-256-GCM key that lives in the Android Keystore (hardware-backed
 * where the phone has it; it can't be read out) and kept in `noBackupFilesDir/friends-keys`. A phone whose Keystore
 * refuses (a few old or odd ROMs) keeps them as a plain file there instead, as iOS falls back to a protected file.
 */
object FriendSecrets {
    private const val ALIAS = "nl.haltewekker.friends.v1"
    private const val PLAIN = "p:"
    private const val LOCKED = "k:"

    private fun dir(c: Context) = File(c.noBackupFilesDir, "friends-keys").also { it.mkdirs() }
    private fun file(c: Context, name: String) = File(dir(c), name)

    private fun key(): SecretKey? = try {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
            generateKey()
        }
    } catch (_: Exception) { null }

    fun get(c: Context, name: String): ByteArray? {
        val text = try { file(c, name).takeIf { it.exists() }?.readText() } catch (_: Exception) { null } ?: return null
        return when {
            text.startsWith(PLAIN) -> B64u.decode(text.removePrefix(PLAIN))
            text.startsWith(LOCKED) -> {
                val d = B64u.decode(text.removePrefix(LOCKED)) ?: return null
                if (d.size < 12 + 16) return null
                try {
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, key() ?: return null, GCMParameterSpec(128, d.copyOfRange(0, 12)))
                    cipher.doFinal(d.copyOfRange(12, d.size))
                } catch (_: Exception) { null }
            }
            else -> null
        }
    }

    fun set(c: Context, name: String, value: ByteArray?) {
        val f = file(c, name)
        if (value == null) { f.delete(); return }
        val text = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key() ?: throw IllegalStateException("no keystore"))
            LOCKED + B64u.encode(cipher.iv + cipher.doFinal(value))
        } catch (_: Exception) {
            PLAIN + B64u.encode(value)
        }
        val tmp = File(f.parentFile, "$name.tmp")
        tmp.writeText(text)
        tmp.renameTo(f)
    }
}
