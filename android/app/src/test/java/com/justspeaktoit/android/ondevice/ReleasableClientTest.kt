package com.justspeaktoit.android.ondevice

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleasableClientTest {
    private class FakeClient {
        var released = 0
    }

    private val created = mutableListOf<FakeClient>()
    private val client = ReleasableClient(
        create = { FakeClient().also { created += it } },
        release = { it.released++ },
    )

    @Test
    fun testClose_beforeFirstUse_createsNothing_andLaterUseFails() {
        client.close()

        val failure = runCatching { runBlocking { client.use { } } }.exceptionOrNull()
        assertTrue(failure is ReleasableClient.ClosedException)
        assertTrue("a closed client is never created", created.isEmpty())
    }

    @Test
    fun testClose_releasesTheClientOnce_evenWhenCalledAgain() {
        runBlocking { client.use { } }

        client.close()
        client.close()

        assertEquals(1, created.single().released)
    }

    @Test
    fun testClose_duringARequest_waitsForItToFinishBeforeReleasing() = runBlocking {
        val inside = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val request = async {
            client.use {
                inside.complete(Unit)
                finish.await()
                it.released
            }
        }
        inside.await()

        client.close()
        assertEquals("the running request still holds the client", 0, created.single().released)

        finish.complete(Unit)
        assertEquals(0, request.await())
        assertEquals(1, created.single().released)
    }
}
