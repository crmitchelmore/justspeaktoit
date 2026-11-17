package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
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
}
