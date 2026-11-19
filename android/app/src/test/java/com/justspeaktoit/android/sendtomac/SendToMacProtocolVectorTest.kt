package com.justspeaktoit.android.sendtomac

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID

/**
 * Byte-for-byte interoperability with the Mac: every expected value comes from the vectors
 * SpeakCore's `TransportSecureSession` produced in `send_to_mac_protocol.json`
 * (`SendToMacProtocolAndroidExportTests`), never from this implementation.
 */
class SendToMacProtocolVectorTest {
    private val root = JSONObject(SettingsSearchAsset.locate(ASSET).readText())
    private val protocol = SendToMacProtocol.parse(SettingsSearchAsset.locate(ASSET).readText())
    private val vectors = root.getJSONObject("vectors")
    private val clientKey = hex(vectors.getString("clientPrivateKey"))
    private val serverKey = hex(vectors.getString("serverPrivateKey"))
    private val phone = root.getJSONObject("messages").getJSONObject("phone")
    private val mac = root.getJSONObject("messages").getJSONObject("mac")

    @Test
    fun testProtocolConstants_matchTheMac() {
        assertEquals(2, protocol.protocolVersion)
        assertEquals("_speaktransport._tcp", protocol.serviceType)
        assertEquals(root.getJSONObject("serviceTypes").getString("stable"), protocol.serviceType)
        assertEquals(16, protocol.sizes.credentialId)
        assertEquals(32, protocol.sizes.credentialSecret)
    }

    @Test
    fun testX25519_matchesRfc7748() {
        val scalar = hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        val point = hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        assertEquals(
            "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
            toHex(X25519.sharedSecret(scalar, point)),
        )
    }

    @Test
    fun testPairingHandshake_matchesTheMacByteForByte() {
        val vector = vectors.getJSONObject("pairing")
        val handshake = ClientHandshake(protocol, PairingSecret.Code(PAIRING_CODE), clientKey)
        assertHandshake(vector, handshake)

        val issued = vector.getJSONObject("issuedCredential")
        val credential = DeviceCredential(UUID.fromString(issued.getString("id")), hex(issued.getString("secret")))
        val opened = macCipher(vector).open(hex(vector.getString("serverFinished")))
        assertEquals(credential, handshake.credentialInServerFinished(opened))
    }

    @Test
    fun testCredentialHandshake_matchesTheMacByteForByte() {
        val issued = vectors.getJSONObject("pairing").getJSONObject("issuedCredential")
        val credential = DeviceCredential(UUID.fromString(issued.getString("id")), hex(issued.getString("secret")))
        val vector = vectors.getJSONObject("credential")
        val handshake = ClientHandshake(protocol, PairingSecret.Credential(credential), clientKey)
        assertHandshake(vector, handshake)

        val opened = macCipher(vector).open(hex(vector.getString("serverFinished")))
        assertNull(handshake.credentialInServerFinished(opened))
    }

    @Test
    fun testPhoneMessages_matchTheMacsJsonExactly() {
        val session = UUID.fromString(SESSION_ID)
        val sessionId = PhoneMessages.uuid(session)
        val at = Instant.parse(TIMESTAMP)
        assertEquals(phone.getString("hello"), PhoneMessages.hello(2, "Pixel 9", DEVICE_ID, "stable"))
        assertEquals(phone.getString("authenticatePairing"), PhoneMessages.authenticate(PAIRING_CODE, at))
        assertEquals(phone.getString("authenticateCredential"), PhoneMessages.authenticate("", at))
        assertEquals(phone.getString("sessionStart"), PhoneMessages.sessionStart(sessionId, "deepgram/nova-3"))
        assertEquals(phone.getString("transcriptChunk"), PhoneMessages.transcriptChunk(sessionId, 1, TEXT, true, at))
        assertEquals(
            phone.getString("sessionEnd"),
            PhoneMessages.sessionEnd(sessionId, TEXT, 12.5, PhoneMessages.wordCount(TEXT)),
        )
        assertEquals(phone.getString("pong"), PhoneMessages.PONG)
    }

    @Test
    fun testMacMessages_parseAsTheMacSendsThem() {
        val success = MacMessages.parse(bytes(mac.getString("authResultSuccess"))) as MacMessage.AuthResult
        assertTrue(success.success)
        assertEquals("stable", success.releaseTrain)
        assertEquals("vector-session-token", success.sessionToken)
        val legacy = MacMessages.parse(bytes(mac.getString("authResultLegacySuccess"))) as MacMessage.AuthResult
        assertNull(legacy.releaseTrain)
        val failure = MacMessages.parse(bytes(mac.getString("authResultFailure"))) as MacMessage.AuthResult
        assertEquals("Invalid pairing code", failure.errorMessage)
        assertEquals(MacMessage.Ack(1), MacMessages.parse(bytes(mac.getString("ack"))))
        assertEquals(MacMessage.Error(401, "Authentication failed"), MacMessages.parse(bytes(mac.getString("error"))))
        assertEquals(MacMessage.Ping, MacMessages.parse(bytes(mac.getString("ping"))))
        assertEquals("Invalid pairing code", MacMessages.rejection(bytes(mac.getString("authResultFailure"))))
        assertEquals("Authentication failed", MacMessages.rejection(bytes(mac.getString("error"))))
    }

    private fun assertHandshake(vector: JSONObject, handshake: ClientHandshake) {
        assertEquals(vector.getString("clientPublicKey"), toHex(X25519.publicKey(clientKey)))
        assertEquals(vector.getString("serverPublicKey"), toHex(X25519.publicKey(serverKey)))
        assertEquals(vector.getString("clientFrame"), String(handshake.frame, Charsets.UTF_8))

        val serverFrame = bytes(vector.getString("serverFrame"))
        val serverPublic = MacMessages.keyShare(serverFrame, protocol)
        assertArrayEquals(X25519.publicKey(serverKey), serverPublic)
        val schedule = TransportKeySchedule.derive(protocol, clientKey, serverPublic!!, handshake.frame, serverFrame)
        assertEquals(vector.getString("sharedSecret"), toHex(schedule.sharedSecret))
        assertEquals(vector.getString("transcriptHash"), toHex(schedule.transcriptHash))
        val preSharedKey = TransportKeySchedule.preSharedKey(protocol, handshake.secret)
        assertEquals(vector.getString("preSharedKey"), toHex(preSharedKey))
        val (clientToServer, serverToClient) = schedule.directionKeys(preSharedKey)
        assertEquals(vector.getString("clientToServerKey"), toHex(clientToServer))
        assertEquals(vector.getString("serverToClientKey"), toHex(serverToClient))

        val finished = handshake.finish(serverFrame)
        assertEquals(vector.getString("clientFinished"), toHex(finished.frame))
        val message = vector.getJSONObject("phoneMessage")
        assertEquals(phone.getString("hello"), message.getString("json"))
        assertEquals(message.getString("sealed"), toHex(finished.keys.outbound.seal(bytes(message.getString("json")))))

        // The Mac's own frames open in order: "server finished" at 0, then its reply.
        assertTrue(finished.keys.inbound.open(hex(vector.getString("serverFinished"))).isNotEmpty())
        val reply = vector.getJSONObject("macMessage")
        assertEquals(reply.getString("json"), String(finished.keys.inbound.open(hex(reply.getString("sealed"))), Charsets.UTF_8))
    }

    private fun macCipher(vector: JSONObject) = FrameCipher(hex(vector.getString("serverToClientKey")), protocol)

    companion object {
        const val ASSET = "app/src/main/assets/send_to_mac_protocol.json"
        const val PAIRING_CODE = "482915"
        const val DEVICE_ID = "8C0F7D2E-5B1A-4E8B-9C3D-2A6F1E0B7C45"
        const val SESSION_ID = "D3B07384-D9A0-4E5B-9F1C-6A2B3C4D5E6F"
        const val TIMESTAMP = "2026-01-02T03:04:05Z"
        const val TEXT = "Hello \"Mac\"\nfrom Android — café 🎙️ / done"

        fun bytes(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

        fun hex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        fun toHex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}
