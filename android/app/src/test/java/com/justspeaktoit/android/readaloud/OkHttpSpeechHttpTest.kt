package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import kotlin.concurrent.thread

/** A speech request carries its key in a header, so a redirect must never take it to another host. */
class OkHttpSpeechHttpTest {
    @Test(timeout = 20_000)
    fun testRedirect_isReturnedAndTheKeyNeverReachesTheOtherHost() = runBlocking {
        val loopback = InetAddress.getLoopbackAddress()
        ServerSocket(0, 1, loopback).use { other ->
            ServerSocket(0, 1, loopback).use { provider ->
                val sent = StringBuilder()
                val answering = thread(isDaemon = true) {
                    provider.accept().use { socket ->
                        val reader = socket.getInputStream().bufferedReader()
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            sent.appendLine(line)
                        }
                        val location = "http://${loopback.hostAddress}:${other.localPort}/steal"
                        socket.getOutputStream().write(
                            "HTTP/1.1 302 Found\r\nLocation: $location\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                                .toByteArray(),
                        )
                        socket.getOutputStream().flush()
                    }
                }

                val response = OkHttpSpeechHttp().send(
                    SpeechHttpRequest(
                        method = "GET",
                        url = "http://${loopback.hostAddress}:${provider.localPort}/speak",
                        headers = mapOf("xi-api-key" to "secret"),
                        body = ByteArray(0),
                    ),
                )
                answering.join(5_000)

                assertEquals(302, response.status)
                assertTrue(sent.contains("xi-api-key: secret"))
                other.soTimeout = 500
                val followed = try {
                    other.accept().close()
                    true
                } catch (_: SocketTimeoutException) {
                    false
                }
                assertFalse("the redirect was followed to another host", followed)
            }
        }
    }

    /** Answers [times] connections with [response], ignoring each request. */
    private fun answering(server: ServerSocket, times: Int, response: String) = thread(isDaemon = true) {
        repeat(times) {
            server.accept().use { socket ->
                val reader = socket.getInputStream().bufferedReader()
                do {
                    val line = reader.readLine()
                } while (!line.isNullOrEmpty())
                socket.getOutputStream().write(response.toByteArray())
                socket.getOutputStream().flush()
            }
        }
    }

    @Test(timeout = 20_000)
    fun testSend_stopsReadingAtTheRequestsOwnLimit() = runBlocking {
        val loopback = InetAddress.getLoopbackAddress()
        ServerSocket(0, 1, loopback).use { server ->
            val body = "x".repeat(100)
            answering(server, 1, "HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body")
            val request = SpeechHttpRequest(
                method = "GET",
                url = "http://${loopback.hostAddress}:${server.localPort}/voices",
                headers = emptyMap(),
                body = ByteArray(0),
                maxResponseBytes = 10,
            )
            val refused = try {
                OkHttpSpeechHttp().send(request)
                false
            } catch (_: SpeechResponseTooLarge) {
                true
            }
            assertTrue("a listing larger than its own limit was read", refused)
        }
    }

    @Test(timeout = 20_000)
    fun testRealtimeConnector_reportsARefusedHandshakeWhetherItReceivesOrSendsFirst() = runBlocking {
        val loopback = InetAddress.getLoopbackAddress()
        ServerSocket(0, 2, loopback).use { server ->
            answering(server, 2, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            val url = "ws://${loopback.hostAddress}:${server.localPort}/realtime"

            val receiving = OkHttpRealtimeConnector().open(url, emptyMap())
            val received = try {
                receiving.receive()
                null
            } catch (error: IOException) {
                error
            }
            assertEquals(401, (received as? RealtimeHandshakeRefused)?.status)

            // Send until OkHttp has seen the refusal: the failed send must say why, not just that it is closed.
            val sending = OkHttpRealtimeConnector().open(url, emptyMap())
            var sent: IOException? = null
            while (sent == null) {
                sent = try {
                    sending.send("{}")
                    null
                } catch (error: IOException) {
                    error
                }
                if (sent == null) delay(10)
            }
            assertEquals(401, (sent as? RealtimeHandshakeRefused)?.status)
        }
    }

    @Test
    fun testBoundedBytes_readsUpToTheLimitAndRefusesMoreWhateverTheDeclaredLength() {
        fun body(size: Int, declared: Long = -1) = Buffer().write(ByteArray(size) { it.toByte() }).asResponseBody(null, declared)

        assertArrayEquals(ByteArray(8) { it.toByte() }, OkHttpSpeechHttp.boundedBytes(body(8), 8))
        assertThrows(SpeechResponseTooLarge::class.java) { OkHttpSpeechHttp.boundedBytes(body(9), 8) }
        assertThrows(SpeechResponseTooLarge::class.java) { OkHttpSpeechHttp.boundedBytes(body(0, declared = 9), 8) }
    }
}
