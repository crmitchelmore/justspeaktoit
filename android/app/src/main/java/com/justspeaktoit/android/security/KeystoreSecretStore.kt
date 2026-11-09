package com.justspeaktoit.android.security

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * Builds the app's [SecretStore]: ciphertext lives in private SharedPreferences (excluded from
 * backup and device transfer), and the AES key is generated inside, and never leaves, the Android
 * Keystore.
 */
internal object KeystoreSecretStore {
    private const val KEY_ALIAS = "jsti.secrets.v1"
    private const val PREFS = "jsti_secrets"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_BITS = 256

    @Volatile private var instance: SecretStore? = null

    /** One shared store per process, so its locking covers every caller. */
    @Synchronized
    fun create(context: Context): SecretStore = instance ?: run {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        EncryptedSecretStore(PreferencesBacking(prefs), ::keystoreKey).also { instance = it }
    }

    @Synchronized
    private fun keystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(KEY_BITS)
            .setRandomizedEncryptionRequired(true)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }

    private class PreferencesBacking(private val prefs: SharedPreferences) : SecretBacking {
        override fun get(key: String): String? = prefs.getString(key, null)

        override fun put(key: String, value: String) {
            prefs.edit { putString(key, value) }
        }

        override fun delete(key: String) {
            prefs.edit { remove(key) }
        }

        override fun keys(): Set<String> = prefs.all.keys
    }
}
