package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.dictation.DictationFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepgramLiveSessionTest {
    private val scheduler = ManualScheduler()
    private val sockets = FakeSockets()
    private val listener = RecordingListener()

    private fun session(catalogId: String = NOVA, language: String? = "en", keyterms: List<String> = emptyList()) =
        DeepgramLiveSession(liveModel(catalogId), language, keyterms, scheduler, sockets, listener)

    private fun nova(text: String, final: Boolean) =
        """{"type":"Results","is_final":$final,"channel":{"alternatives":[{"transcript":"$text"}]}}"""

    @Test
    fun testNovaUrl_carriesModelLanguageAndDistinctKeyterms() {
        val url = DeepgramLiveSession.url(liveModel(NOVA), "en", listOf("Kubernetes", " ", "kubernetes", "Just Speak"))

        assertTrue(url, url.startsWith("wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000"))
        assertTrue(url, url.contains("&interim_results=true"))
        assertTrue(url, url.contains("&language=en"))
        assertEquals(listOf("keyterm=Kubernetes", "keyterm=Just%20Speak"), url.split('&').filter { it.startsWith("keyterm=") })
    }

    @Test
    fun testFluxEnglishUrl_usesV2AndSendsNoLanguage() {
        val url = DeepgramLiveSession.url(liveModel(FLUX_EN), "fr", emptyList())

        assertTrue(url, url.startsWith("wss://api.deepgram.com/v2/listen?model=flux-general-en"))
        assertFalse(url, url.contains("language"))
        assertFalse(url, url.contains("interim_results"))
    }

    @Test
    fun testAudioBeforeTheSocketOpens_isHeldThenSentInOrder() {
        val session = session()
        session.connect("dg-key")
        session.append(byteArrayOf(1, 2))
        session.append(byteArrayOf(3, 4))
        assertTrue(sockets.last.binaries.isEmpty())
        assertEquals("Token dg-key", sockets.last.request.headers["Authorization"])

        sockets.last.serverOpen()

        assertEquals(listOf(listOf<Byte>(1, 2), listOf<Byte>(3, 4)), sockets.last.binaries.map { it.toList() })
    }

    @Test
    fun testInterimsReplace_finalsAppend_andTheStopReturnsOnlyFinals() {
        val session = session()
        session.connect("dg-key")
        sockets.last.serverOpen()
        session.append(pcm(100))

        sockets.last.serverSends(nova("hello wor", final = false))
        sockets.last.serverSends(nova("hello world", final = false))
        sockets.last.serverSends(nova("Hello world.", final = true))
        sockets.last.serverSends(nova("how", final = false))
        assertEquals(listOf("hello wor", "hello world", "Hello world.", "Hello world. how"), listener.partials)

        session.finish()
        assertEquals(DeepgramLiveSession.CLOSE_STREAM, sockets.last.texts.last())
        assertNull(listener.outcome)
        sockets.last.serverSends("""{"type":"Metadata"}""")

        assertEquals(LiveOutcome.Completed("Hello world."), listener.outcome)
        assertEquals(1000, sockets.last.closedWith)
        assertTrue(scheduler.isShutdown)
    }

    @Test
    fun testFluxStop_foldsTheOpenTurnIntoTheResultAfterItsGrace() {
        val session = session(FLUX_EN)
        session.connect("dg-key")
        sockets.last.serverOpen()
        session.append(pcm(100))
        sockets.last.serverSends("""{"type":"TurnInfo","event":"EndOfTurn","transcript":"First turn."}""")
        sockets.last.serverSends("""{"type":"TurnInfo","event":"Update","transcript":"second"}""")

        session.finish()
        scheduler.advanceBy(2_999)
        assertNull(listener.outcome)
        scheduler.advanceBy(1)

        assertEquals(LiveOutcome.Completed("First turn. second"), listener.outcome)
    }

    @Test
    fun testRejectedKey_failsAsInvalidKeyWithoutAnotherAttempt() {
        val session = session()
        session.connect("bad")
        session.append(pcm(100))

        sockets.last.serverFails(httpStatus = 401)

        assertEquals(LiveOutcome.Failed(DictationFailure.InvalidKey, ""), listener.outcome)
        assertEquals(1, sockets.opened.size)
    }

    @Test
    fun testDropMidSession_failsKeepingTheTextHeard() {
        val session = session()
        session.connect("dg-key")
        sockets.last.serverOpen()
        sockets.last.serverSends(nova("kept words", final = true))

        sockets.last.serverCloses(1011)

        assertEquals(LiveOutcome.Failed(DictationFailure.Network, "kept words"), listener.outcome)
    }

    @Test
    fun testStopThatNeverConnects_endsWithinTheFinishDeadline() {
        val session = session()
        session.connect("dg-key")
        session.append(pcm(100))

        session.finish()
        scheduler.advanceBy(5_000)

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
        assertTrue(sockets.last.cancelled)
    }

    @Test
    fun testStopWithNoAudio_completesEmptyAtOnce() {
        val session = session()
        session.connect("dg-key")

        session.finish()

        assertEquals(LiveOutcome.Completed(""), listener.outcome)
    }

    @Test
    fun testCancel_endsSilentlyAndIgnoresLateMessages() {
        val session = session()
        session.connect("dg-key")
        sockets.last.serverOpen()

        session.cancel()
        sockets.last.serverSends(nova("late", final = true))

        assertTrue(listener.outcomes.isEmpty())
        assertTrue(listener.partials.isEmpty())
        assertTrue(sockets.last.cancelled)
    }

    @Test
    fun testSocketThatStopsDraining_failsAsAStallRatherThanDroppingAudio() {
        val session = session()
        session.connect("dg-key")
        sockets.last.serverOpen()
        sockets.last.queuedBytes = 16_000L * 2 * 10 + 1

        session.append(pcm(100))

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
    }

    private companion object {
        const val NOVA = "deepgram/nova-3-streaming"
        const val FLUX_EN = "deepgram/flux-general-en-streaming"
    }
}
