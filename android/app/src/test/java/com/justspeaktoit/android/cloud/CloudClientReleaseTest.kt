package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** A provider that accepts the request and never answers, so only the handle can end the call. */
class CloudClientReleaseTest {
    private lateinit var server: ServerSocket
    private val accepted = CopyOnWriteArrayList<Socket>()
    private val connected = CountDownLatch(1)

    @Before
    fun startSilentServer() {
        server = ServerSocket(0)
        thread(isDaemon = true) {
            runCatching {
                while (true) {
                    accepted += server.accept()
                    connected.countDown()
                }
            }
        }
    }

    @After
    fun stopServer() {
        accepted.forEach { runCatching { it.close() } }
        server.close()
    }

    @Test
    fun testRelease_throwsRequestReleasedNotNetworkFailure() {
        val error = callAndEnd { it.release() }
        assertTrue("expected a release, got $error", error is RequestReleasedException)
    }

    @Test
    fun testCancel_stillReportsNetworkFailure() {
        val error = callAndEnd { it.cancel() }
        assertTrue("expected a CloudException, got $error", error is CloudException)
        assertEquals(DictationFailure.Network, (error as CloudException).failure)
    }

    private fun callAndEnd(end: (CallHandle) -> Unit): Throwable? {
        val call = CallHandle()
        var error: Throwable? = null
        val worker = thread {
            error = runCatching {
                CloudClient().post("http://127.0.0.1:${server.localPort}/v1", "key", "application/json", call) {
                    it.doOutput = true
                    it.outputStream.use { out -> out.write("{}".toByteArray()) }
                }
            }.exceptionOrNull()
        }
        assertTrue(connected.await(5, TimeUnit.SECONDS))
        Thread.sleep(200)
        end(call)
        worker.join(5_000)
        assertTrue("the call did not end", !worker.isAlive)
        return error
    }
}
