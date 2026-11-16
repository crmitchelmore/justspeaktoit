package com.justspeaktoit.android.sendtomac

import com.justspeaktoit.android.security.SecretStore
import org.json.JSONException
import org.json.JSONObject
import java.util.Base64
import java.util.UUID

/** The Mac this phone is paired with and the device credential it issued. */
internal data class MacPairing(val macName: String, val credential: DeviceCredential)

/**
 * Keeps the Send to Mac pairing encrypted with the Keystore key that protects API keys. The pairing
 * code itself is never stored: only the credential the Mac issued for it (#1643).
 */
internal class SendToMacPairingStore(
    private val secrets: SecretStore,
    private val protocol: SendToMacProtocol,
) {
    fun pairing(): MacPairing? {
        val stored = secrets.read(PAIRING) ?: return null
        return try {
            val root = JSONObject(stored)
            val secret = Base64.getDecoder().decode(root.getString(SECRET))
            if (secret.size != protocol.sizes.credentialSecret) return null
            MacPairing(root.getString(MAC), DeviceCredential(UUID.fromString(root.getString(CREDENTIAL_ID)), secret))
        } catch (_: JSONException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    fun save(pairing: MacPairing) {
        val json = JSONObject()
            .put(MAC, pairing.macName)
            .put(CREDENTIAL_ID, PhoneMessages.uuid(pairing.credential.id))
            .put(SECRET, Base64.getEncoder().encodeToString(pairing.credential.secret))
        secrets.write(PAIRING, json.toString())
    }

    fun clear() = secrets.remove(PAIRING)

    /** A stable identifier the Mac lists this phone under; made once, kept with the pairing. */
    fun deviceId(): String = secrets.read(DEVICE_ID) ?: PhoneMessages.uuid(UUID.randomUUID()).also {
        secrets.write(DEVICE_ID, it)
    }

    companion object {
        const val PAIRING = "sendToMac.pairing"
        const val DEVICE_ID = "sendToMac.deviceId"
        private const val MAC = "mac"
        private const val CREDENTIAL_ID = "credentialId"
        private const val SECRET = "secret"
    }
}
