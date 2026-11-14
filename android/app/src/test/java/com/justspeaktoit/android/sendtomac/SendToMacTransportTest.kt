package com.justspeaktoit.android.sendtomac

import com.justspeaktoit.android.dictation.MemorySecrets
import com.justspeaktoit.android.sendtomac.SendToMacProtocolVectorTest.Companion.ASSET
import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import kotlin.concurrent.thread

class SendToMacTransportTest {
    private val protocol = SendToMacProtocol.parse(SettingsSearchAsset.locate(ASSET).readText())

    @Test
    fun testAcceptValue_matchesRfc6455() {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WebSocketConnection.acceptValue("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test
    fun testUpgradeResponse_withoutTheRightAcceptKey_isRefused() {
        val key = "dGhlIHNhbXBsZSBub25jZQ=="
        WebSocketConnection.checkUpgradeResponse(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            key,
        )
        for (head in listOf(
            "HTTP/1.1 404 Not Found",
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: wrong",
        )) {
            try {
                WebSocketConnection.checkUpgradeResponse(head, key)
                fail("Accepted $head")
            } catch (_: WebSocketProtocolException) {
                // Expected.
            }
        }
    }

    @Test
    fun testWebSocket_masksWhatItSends_joinsFragments_andAnswersPings() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            var received: ByteArray? = null
            var pong: ByteArray? = null
            val mac = thread {
                server.accept().use { socket ->
                    val input = socket.getInputStream()
                    val head = readHead(input)
                    val key = head.lines().first { it.startsWith("Sec-WebSocket-Key:") }.substringAfter(':').trim()
                    val output = socket.getOutputStream()
                    output.write(
                        ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                            "Sec-WebSocket-Accept: ${WebSocketConnection.acceptValue(key)}\r\n\r\n").toByteArray(),
                    )
                    received = readClientFrame(input).second
                    // A binary message in two fragments with a ping between them.
                    output.write(byteArrayOf(0x02, 0x03) + "abc".toByteArray())
                    output.write(byteArrayOf(0x89.toByte(), 0x01, 0x70))
                    output.write(byteArrayOf(0x80.toByte(), 0x02) + "de".toByteArray())
                    output.flush()
                    pong = readClientFrame(input).let { (opcode, payload) -> byteArrayOf(opcode.toByte()) + payload }
                }
            }
            WebSocketConnection.open(server.inetAddress, server.localPort, "/", 5_000, 1_024).use { connection ->
                val large = ByteArray(300) { it.toByte() }
                connection.send(large)
                assertArrayEquals("abcde".toByteArray(), connection.receive(5_000))
                mac.join(5_000)
                assertArrayEquals(large, received)
            }
            assertArrayEquals(byteArrayOf(0x0A, 0x70), pong)
        }
    }

    @Test
    fun testServiceName_unescapesDnsEscapes() {
        assertEquals("Chris's MacBook Pro", MacDiscovery.unescapeServiceName("Chris's\\032MacBook\\032Pro"))
        assertEquals("Mac.lan", MacDiscovery.unescapeServiceName("Mac\\.lan"))
        assertEquals("Café Mac", MacDiscovery.unescapeServiceName("Caf\\195\\169 Mac"))
        assertEquals("Plain", MacDiscovery.unescapeServiceName("Plain"))
    }

    @Test
    fun testPairingStore_keepsTheCredential_andForgetsIt() {
        val secrets = MemorySecrets()
        val store = SendToMacPairingStore(secrets, protocol)
        val pairing = MacPairing("Studio", DeviceCredential(UUID.randomUUID(), ByteArray(32) { it.toByte() }))
        assertNull(store.pairing())

        store.save(pairing)
        assertEquals(pairing, store.pairing())
        val deviceId = store.deviceId()
        assertEquals(deviceId, store.deviceId())

        store.clear()
        assertNull(store.pairing())
        assertEquals(deviceId, store.deviceId())
        assertTrue(secrets.names().none { it.startsWith("sendToMac.pairing") })
    }

    @Test
    fun testPairingStore_ignoresAMalformedPairing() {
        val store = SendToMacPairingStore(MemorySecrets(SendToMacPairingStore.PAIRING to "{\"mac\":\"Studio\"}"), protocol)
        assertNull(store.pairing())
    }

    private fun readHead(input: InputStream): String {
        val head = ByteArrayOutputStream()
        while (!head.toString(Charsets.US_ASCII.name()).endsWith("\r\n\r\n")) head.write(input.read())
        return head.toString(Charsets.US_ASCII.name())
    }

    /** One client frame, which must be final and masked: its opcode and unmasked payload. */
    private fun readClientFrame(input: InputStream): Pair<Int, ByteArray> {
        val first = input.read()
        val second = input.read()
        assertTrue("Client frames must be final", first and 0x80 != 0)
        assertTrue("Client frames must be masked", second and 0x80 != 0)
        val length = when (val marker = second and 0x7F) {
            126 -> (input.read() shl 8) or input.read()
            127 -> (0 until 8).fold(0L) { acc, _ -> (acc shl 8) or input.read().toLong() }.toInt()
            else -> marker
        }
        val mask = ByteArray(4) { input.read().toByte() }
        val payload = ByteArray(length) { (input.read() xor mask[it % 4].toInt()).toByte() }
        return (first and 0x0F) to payload
    }
}
