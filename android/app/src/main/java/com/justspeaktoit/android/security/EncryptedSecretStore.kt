package com.justspeaktoit.android.security

import java.security.GeneralSecurityException
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Stores named secrets such as provider API keys. Values never leave the device in plain text. */
internal interface SecretStore {
    fun read(name: String): String?

    fun write(name: String, value: String)

    fun remove(name: String)

    fun names(): Set<String>
}

/** Minimal persistence the encrypted store needs; production uses private SharedPreferences. */
internal interface SecretBacking {
    fun get(key: String): String?

    fun put(key: String, value: String)

    fun delete(key: String)

    fun keys(): Set<String>
}

/**
 * AES-256-GCM authenticated encryption. The cipher generates a fresh IV for every value, and the
 * secret's name is bound as associated data, so a ciphertext cannot be moved to another name.
 */
internal object SealedBox {
    private const val VERSION = "v1:"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    fun seal(key: SecretKey, plaintext: ByteArray, associatedData: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(associatedData)
        val iv = cipher.iv
        check(iv.size == IV_BYTES) { "Unexpected IV length" }
        val sealed = iv + cipher.doFinal(plaintext)
        return VERSION + Base64.getEncoder().encodeToString(sealed)
    }

    /**
     * @throws InvalidSealedValueException when the value is malformed, tampered with, moved to another
     *   name or sealed by a different key: it can never be opened and is safe to discard.
     * @throws GeneralSecurityException for operational failures (for example a Keystore that is
     *   briefly unavailable), which say nothing about the stored value.
     */
    fun open(key: SecretKey, encoded: String, associatedData: ByteArray): ByteArray {
        if (!encoded.startsWith(VERSION)) throw InvalidSealedValueException("Unknown sealed format")
        val bytes = try {
            Base64.getDecoder().decode(encoded.removePrefix(VERSION))
        } catch (e: IllegalArgumentException) {
            throw InvalidSealedValueException("Malformed sealed value", e)
        }
        if (bytes.size < IV_BYTES + TAG_BITS / 8) throw InvalidSealedValueException("Truncated sealed value")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES))
        cipher.updateAAD(associatedData)
        return try {
            cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES)
        } catch (e: AEADBadTagException) {
            throw InvalidSealedValueException("Authentication failed", e)
        }
    }
}

/** A sealed value that can never be opened with the current key and name. */
internal class InvalidSealedValueException(message: String, cause: Throwable? = null) :
    GeneralSecurityException(message, cause)

/**
 * Encrypts every value with a key supplied by [keyProvider] (the Android Keystore in production).
 * A value that fails authentication, for example after the Keystore key was lost in a device
 * restore, is deleted and reported as absent so the user is asked to enter it again. Any other
 * failure is thrown and the stored value is kept.
 */
internal class EncryptedSecretStore(
    private val backing: SecretBacking,
    private val keyProvider: () -> SecretKey,
) : SecretStore {
    // Serialised so a read that discards an invalid value cannot delete a concurrent replacement.
    @Synchronized
    override fun read(name: String): String? {
        requireValidName(name)
        val sealed = backing.get(name) ?: return null
        // Only a value proven unopenable is discarded; Keystore or cipher failures propagate and keep it.
        return try {
            SealedBox.open(keyProvider(), sealed, name.toByteArray()).toString(Charsets.UTF_8)
        } catch (e: InvalidSealedValueException) {
            backing.delete(name)
            null
        }
    }

    @Synchronized
    override fun write(name: String, value: String) {
        requireValidName(name)
        if (value.isEmpty()) {
            backing.delete(name)
            return
        }
        backing.put(name, SealedBox.seal(keyProvider(), value.toByteArray(), name.toByteArray()))
    }

    @Synchronized
    override fun remove(name: String) {
        requireValidName(name)
        backing.delete(name)
    }

    override fun names(): Set<String> = backing.keys().filterTo(sortedSetOf()) { NAME.matches(it) }

    companion object {
        /** Matches the Mac app's credential identifiers, for example `openai.apiKey`. */
        private val NAME = Regex("[A-Za-z][A-Za-z0-9_.-]{0,63}")

        fun isValidName(name: String): Boolean = NAME.matches(name)

        private fun requireValidName(name: String) {
            require(isValidName(name)) { "Secret names use letters, digits, dots, dashes and underscores" }
        }
    }
}
