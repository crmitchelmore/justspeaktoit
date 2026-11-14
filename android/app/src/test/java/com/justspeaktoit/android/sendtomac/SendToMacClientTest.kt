package com.justspeaktoit.android.sendtomac

import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.ASSET
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.DEVICE_ID
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.SESSION_ID
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.TEXT
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.TIMESTAMP
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.bytes
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.hex
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.toHex
import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException
import java.time.Instant
import java.util.UUID

/**
 * The phone's whole exchange against the Mac's recorded side of the SpeakCore vectors: what the
 * phone sends must open on the Mac as exactly the Mac's expected JSON.
 */
class SendToMacClientTest {
    private val asset = SettingsSearchAsset.locate(ASSET).readText()
    private val protocol = SendToMacProtocol.parse(asset)
    private val root = JSONObject(asset)
    private val vectors = root.getJSONObject("vectors")
    private val phone = root.getJSONObject("messages").getJSONObject("phone")
    private val replies = root.getJSONObject("messages").getJSONObject("mac")
    private val issued = vectors.getJSONObject("pairing").getJSONObject("issuedCredential").let {
        DeviceCredential(UUID.fromString(it.getString("id")), hex(it.getString("secret")))
    }
    private val client = SendToMacClient(
        protocol = protocol,
        deviceName = { "Pixel 9" },
        deviceId = { DEVICE_ID },
        clock = { Instant.parse(TIMESTAMP) },
        privateKey = { hex(vectors.getString("clientPrivateKey")) },
    )

    @Test
    fun testPair_returnsTheIssuedCredential_andSendsTheMacsExpectedFrames() {
        val vector = vectors.getJSONObject("pairing")
        val side = MacSide(vector, replies.getString("authResultSuccess"))

        assertEquals(issued, client.pair("Studio", "482 915", side.connector))

        assertEquals(vector.getString("clientFrame"), String(side.sent[0], Charsets.UTF_8))
        assertEquals(vector.getString("clientFinished"), toHex(side.sent[1]))
        assertEquals(vector.getJSONObject("phoneMessage").getString("sealed"), toHex(side.sent[2]))
        assertEquals(listOf(phone.getString("hello"), phone.getString("authenticatePairing")), side.openedPhoneMessages())
        assertTrue(side.closed)
    }

    @Test
    fun testSend_deliversTheTranscript_andReturnsOnceAcknowledged() {
        val side = MacSide(vectors.getJSONObject("credential"), replies.getString("authResultSuccess"), replies.getString("ack"))

        client.send("Studio", issued, TEXT, "deepgram/nova-3", 12.5, side.connector, UUID.fromString(SESSION_ID))

        assertEquals(
            listOf("hello", "authenticateCredential", "sessionStart", "transcriptChunk", "sessionEnd").map(phone::getString),
            side.openedPhoneMessages(),
        )
        assertTrue(side.closed)
    }

    @Test
    fun testSend_answersPingsWhileWaitingForTheAck() {
        val side = MacSide(
            vectors.getJSONObject("credential"),
            replies.getString("authResultSuccess"),
            replies.getString("ping"),
            replies.getString("ack"),
        )

        client.send("Studio", issued, TEXT, "deepgram/nova-3", 12.5, side.connector, UUID.fromString(SESSION_ID))

        assertEquals(phone.getString("pong"), side.openedPhoneMessages()[4])
    }

    @Test
    fun testPair_wrongCode_reportsTheMacsPlaintextRefusal() {
        val vector = vectors.getJSONObject("pairing")
        val side = MacSide(vector, plaintextAfterHandshake = replies.getString("authResultFailure"))

        assertFailure(SendToMacFailure.Rejected("Invalid pairing code")) { client.pair("Studio", "000000", side.connector) }
        assertTrue(side.closed)
    }

    @Test
    fun testSend_revokedCredential_isRejectedNotRetriedWithACode() {
        val side = MacSide(vectors.getJSONObject("credential"), replies.getString("error"))

        assertFailure(SendToMacFailure.Rejected("Authentication failed")) {
            client.send("Studio", issued, TEXT, "", 0.0, side.connector)
        }
        assertEquals(2, side.openedPhoneMessages().size)
    }

    @Test
    fun testSend_alphaMac_isAReleaseTrainMismatch() {
        val side = MacSide(vectors.getJSONObject("credential"), replies.getString("authResultAlpha"))

        assertFailure(SendToMacFailure.ReleaseTrainMismatch) { client.send("Studio", issued, TEXT, "", 0.0, side.connector) }
    }

    @Test
    fun testSend_withoutAnAck_timesOut() {
        val side = MacSide(vectors.getJSONObject("credential"), replies.getString("authResultSuccess"))

        assertFailure(SendToMacFailure.AcknowledgementTimedOut) {
            client.send("Studio", issued, TEXT, "", 0.0, side.connector)
        }
        assertTrue(side.closed)
    }

    @Test
    fun testSend_unreachableMac_namesTheMac() {
        assertFailure(SendToMacFailure.Unreachable("Studio")) {
            client.send("Studio", issued, TEXT, "", 0.0, SendToMacClient.Connector { _, _ -> throw IOException("no route") })
        }
    }

    @Test
    fun testPair_invalidCode_neverConnects() {
        var opened = false
        assertFailure(SendToMacFailure.InvalidCode) {
            client.pair("Studio", "48291") { _, _ ->
                opened = true
                throw IOException("unused")
            }
        }
        assertFalse(opened)
    }

    @Test
    fun testNormalizedPairingCode_acceptsSixDigitsWithSpaces() {
        assertEquals("482915", SendToMacClient.normalizedPairingCode(" 482 915 "))
        assertNull(SendToMacClient.normalizedPairingCode("48291a"))
        assertNull(SendToMacClient.normalizedPairingCode("٤٨٢٩١٥"))
    }

    private fun assertFailure(expected: SendToMacFailure, block: () -> Unit) {
        try {
            block()
            fail("Expected $expected")
        } catch (failure: SendToMacFailure) {
            assertEquals(expected, failure)
        }
    }

    /**
     * The Mac's side of one vector session: its recorded key share and "server finished", then
     * [sealedReplies] sealed in order. Every frame the phone sends is kept for the Mac to open.
     */
    private inner class MacSide(
        private val vector: JSONObject,
        vararg sealedReplies: String,
        plaintextAfterHandshake: String? = null,
    ) : FrameTransport {
        val sent = mutableListOf<ByteArray>()
        var closed = false
        override var maximumMessageBytes = 0
        private val outbound = FrameCipher(hex(vector.getString("serverToClientKey")), protocol)
        private val queue = ArrayDeque<ByteArray>()
        val connector = SendToMacClient.Connector { _, limit ->
            maximumMessageBytes = limit
            this
        }

        init {
            queue += bytes(vector.getString("serverFrame"))
            if (plaintextAfterHandshake != null) {
                queue += bytes(plaintextAfterHandshake)
            } else {
                val finished = hex(vector.getString("serverFinished"))
                outbound.open(finished)
                queue += finished
                sealedReplies.forEach { queue += outbound.seal(bytes(it)) }
            }
        }

        override fun send(frame: ByteArray) {
            sent += frame
        }

        override fun receive(timeoutMs: Int): ByteArray = queue.removeFirstOrNull() ?: throw SocketTimeoutException()

        override fun close() {
            closed = true
        }

        /** The phone's sealed messages after "client finished", as the Mac opens them. */
        fun openedPhoneMessages(): List<String> {
            val inbound = FrameCipher(hex(vector.getString("clientToServerKey")), protocol)
            inbound.open(sent[1])
            return sent.drop(2).map { String(inbound.open(it), Charsets.UTF_8) }
        }
    }
}
