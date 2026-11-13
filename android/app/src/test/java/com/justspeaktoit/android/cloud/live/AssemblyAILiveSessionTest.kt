package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLDecoder

class AssemblyAILiveSessionTest {
    private val scheduler = ManualScheduler()
    private val sockets = FakeSockets()
    private val listener = RecordingListener()
    private val model = liveModel("assemblyai/universal-3-6-pro-streaming")

    private fun session(keyterms: List<String> = emptyList()) =
        AssemblyAILiveSession(model, keyterms, scheduler, sockets, listener)

    private fun turn(order: Int, text: String, endOfTurn: Boolean = false, formatted: Boolean = false) =
        """{"type":"Turn","turn_order":$order,"transcript":"$text","end_of_turn":$endOfTurn,"turn_is_formatted":$formatted}"""

    private fun begun(): AssemblyAILiveSession = session().also {
        it.connect("aai-key")
        sockets.last.serverOpen()
        sockets.last.serverSends(BEGIN)
    }

    @Test
    fun testUrl_usesTheEuHostAndBoundedKeyterms() {
        val url = AssemblyAILiveSession.url(model, AssemblyAILiveSession.HOSTS[0], "tok", listOf("Kubernetes", "x".repeat(51)))

        assertTrue(url, url.startsWith("wss://streaming.eu.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le"))
        assertTrue(url, url.contains("&speech_model=universal-3-6-pro"))
        assertTrue(url, !url.contains("format_turns"))
        val keyterms = url.split('&').single { it.startsWith("keyterms_prompt=") }.substringAfter('=')
        assertEquals(listOf("Kubernetes"), JSONArray(URLDecoder.decode(keyterms, "UTF-8")).let { a -> List(a.length()) { a.getString(it) } })
    }

    @Test
    fun testAudioWaitsForBegin_thenFlowsIn100msFrames() {
        val session = session()
        session.connect("aai-key")
        sockets.last.serverOpen()
        session.append(pcm(200))
        assertTrue(sockets.last.binaries.isEmpty())

        sockets.last.serverSends(BEGIN)

        assertEquals(listOf(3_200, 3_200), sockets.last.binaries.map { it.size })
    }

    @Test
    fun testTurnsReplaceByOrder_andCommitOnlyWhenEndedAndFormatted() {
        begun()

        sockets.last.serverSends(turn(0, "hel"))
        sockets.last.serverSends(turn(0, "hello there"))
        sockets.last.serverSends(turn(0, "hello there", endOfTurn = true))
        sockets.last.serverSends(turn(0, "Hello there.", endOfTurn = true, formatted = true))
        sockets.last.serverSends(turn(1, "how"))

        assertEquals(listOf("hel", "hello there", "Hello there.", "Hello there. how"), listener.partials)
    }

    @Test
    fun testFailureBeforeBegin_retriesOnceOnTheGlobalHost() {
        val session = session()
        session.connect("aai-key")
        session.append(pcm(100))
        sockets.last.serverFails()

        assertEquals(2, sockets.opened.size)
        assertTrue(sockets.last.request.url.startsWith("wss://streaming.assemblyai.com/"))
        assertNull(listener.outcome)

        // The superseded attempt's late events are ignored.
        sockets.opened.first().serverSends(BEGIN)
        assertTrue(sockets.last.binaries.isEmpty())

        sockets.last.serverFails()
        assertEquals(LiveOutcome.Failed(DictationFailure.Network, ""), listener.outcome)
        assertEquals(2, sockets.opened.size)
    }

    @Test
    fun testSlowBegin_countsAsAFailureAndFallsBackOnce() {
        session().connect("aai-key")
        sockets.last.serverOpen()

        scheduler.advanceBy(AssemblyAILiveSession.BEGIN_DEADLINE_MS)
        assertEquals(2, sockets.opened.size)
        scheduler.advanceBy(AssemblyAILiveSession.BEGIN_DEADLINE_MS)

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
    }

    @Test
    fun testFailureAfterBegin_neverFallsBack_andKeepsTheText() {
        begun()
        sockets.last.serverSends(turn(0, "partial words"))

        sockets.last.serverFails()

        assertEquals(1, sockets.opened.size)
        assertEquals(LiveOutcome.Failed(DictationFailure.Network, "partial words"), listener.outcome)
    }

    @Test
    fun testStop_drainsAudioThenForceEndpointThenTerminateAfterTheFormattedTurn() {
        val session = begun()
        session.append(pcm(130))

        session.finish()
        val socket = sockets.last
        assertEquals(listOf(3_200, 1_600), socket.binaries.map { it.size })
        assertEquals(AssemblyAILiveSession.FORCE_ENDPOINT, socket.sent.last())

        socket.serverSends(turn(0, "Done now.", endOfTurn = true, formatted = true))
        assertEquals(AssemblyAILiveSession.TERMINATE, socket.sent.last())
        socket.serverSends("""{"type":"Termination"}""")

        assertEquals(LiveOutcome.Completed("Done now."), listener.outcome)
        assertEquals(1000, socket.closedWith)
    }

    @Test
    fun testStopWithoutAFinalTurn_terminatesAfterTheFinaliseBudget() {
        val session = begun()
        session.append(pcm(100))
        sockets.last.serverSends(turn(0, "unformatted"))

        session.finish()
        scheduler.advanceBy(1_999)
        assertEquals(AssemblyAILiveSession.FORCE_ENDPOINT, sockets.last.sent.last())
        scheduler.advanceBy(1)
        assertEquals(AssemblyAILiveSession.TERMINATE, sockets.last.sent.last())
        sockets.last.serverCloses()

        assertEquals(LiveOutcome.Completed("unformatted"), listener.outcome)
    }

    @Test
    fun testStopDuringASilentServer_isBoundedByTheFinishDeadline() {
        val session = begun()
        session.append(pcm(100))

        session.finish()
        sockets.last.queuedBytes = 3_200
        scheduler.advanceBy(8_000)

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
    }

    @Test
    fun testUnexpectedTermination_isAFailure() {
        begun()
        sockets.last.serverSends(turn(0, "so far"))

        sockets.last.serverSends("""{"type":"Termination"}""")

        assertEquals(LiveOutcome.Failed(DictationFailure.Server, "so far"), listener.outcome)
    }

    private companion object {
        const val BEGIN = """{"type":"Begin","id":"s1"}"""
    }
}
