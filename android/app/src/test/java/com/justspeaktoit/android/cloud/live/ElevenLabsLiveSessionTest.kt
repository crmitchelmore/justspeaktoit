package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class ElevenLabsLiveSessionTest {
    private val scheduler = ManualScheduler()
    private val sockets = FakeSockets()
    private val listener = RecordingListener()

    private fun session(catalogId: String = SCRIBE_V2, language: String? = "en", keyterms: List<String> = emptyList()) =
        ElevenLabsLiveSession(liveModel(catalogId), language, keyterms, scheduler, sockets, listener)

    private fun started(): ElevenLabsLiveSession = session().also {
        it.connect("el-key")
        sockets.last.serverOpen()
        sockets.last.serverSends(SESSION_STARTED)
    }

    private fun partial(text: String) = """{"message_type":"partial_transcript","text":"$text"}"""

    private fun committed(text: String, timestamped: Boolean = false): String {
        val type = if (timestamped) "committed_transcript_with_timestamps" else "committed_transcript"
        return """{"message_type":"$type","text":"$text"}"""
    }

    private fun audioOf(json: String): ByteArray =
        Base64.getDecoder().decode(JSONObject(json).getString("audio_base_64"))

    @Test
    fun testUrl_carriesModelFormatVadLanguageAndBoundedRealtimeKeyterms() {
        val url = ElevenLabsLiveSession.url(
            liveModel(SCRIBE_V3),
            "fr",
            listOf("Kubernetes", "kubernetes", "a much longer phrase", "x".repeat(21), "<tag>"),
        )

        assertTrue(
            url,
            url.startsWith(
                "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v3_live" +
                    "&audio_format=pcm_16000&commit_strategy=vad",
            ),
        )
        assertTrue(url, url.contains("&language_code=fr"))
        assertEquals(
            listOf("keyterms=Kubernetes", "keyterms=a%20much%20longer%20phrase"),
            url.split('&').filter { it.startsWith("keyterms=") },
        )
    }

    @Test
    fun testAudioWaitsForSessionStarted_thenFlowsAsBase64ChunksInOrder() {
        val session = session()
        session.connect("el-key")
        sockets.last.serverOpen()
        session.append(byteArrayOf(1, 2))
        session.append(byteArrayOf(3, 4))
        assertTrue(sockets.last.texts.isEmpty())
        assertEquals("el-key", sockets.last.request.headers["xi-api-key"])
        assertFalse(sockets.last.request.url.contains("el-key"))

        sockets.last.serverSends(SESSION_STARTED)

        val chunks = sockets.last.texts
        assertEquals(listOf(listOf<Byte>(1, 2), listOf<Byte>(3, 4)), chunks.map { audioOf(it).toList() })
        assertEquals("input_audio_chunk", JSONObject(chunks[0]).getString("message_type"))
        assertEquals(16_000, JSONObject(chunks[0]).getInt("sample_rate"))
    }

    @Test
    fun testPartialsReplace_committedSegmentsAppendOnce_evenWithTheirTimestampedTwin() {
        started()

        sockets.last.serverSends(partial("hel"))
        sockets.last.serverSends(partial("hello there"))
        sockets.last.serverSends(committed("Hello there."))
        sockets.last.serverSends(committed("Hello there.", timestamped = true))
        sockets.last.serverSends(partial("how"))
        sockets.last.serverSends(committed("How are you?", timestamped = true))
        sockets.last.serverSends(committed("How are you?"))

        assertEquals(
            listOf("hel", "hello there", "Hello there.", "Hello there. how", "Hello there. How are you?"),
            listener.partials,
        )
    }

    @Test
    fun testStop_drainsAudioCommitsOnceThenCompletesAfterThePostCommitWindow() {
        val session = started()
        session.append(pcm(100))
        sockets.last.serverSends(partial("almost done"))

        session.finish()
        val socket = sockets.last
        assertEquals(ElevenLabsLiveSession.COMMIT, socket.texts.last())
        assertEquals(3_200, audioOf(socket.texts.first()).size)
        socket.serverSends(partial("ignored while finishing"))
        socket.serverSends(committed("Almost done."))
        scheduler.advanceBy(ElevenLabsLiveSession.POST_COMMIT_WINDOW_MS - 1)
        assertNull(listener.outcome)
        scheduler.advanceBy(1)

        assertEquals(LiveOutcome.Completed("Almost done."), listener.outcome)
        assertEquals(1, socket.texts.count { it == ElevenLabsLiveSession.COMMIT })
        assertEquals(1000, socket.closedWith)
        assertFalse(listener.partials.contains("ignored while finishing"))
    }

    @Test
    fun testPostCommitWindow_startsOnlyOnceTheAudioAndCommitHaveLeft() {
        val session = started()
        session.append(pcm(100))
        sockets.last.queuedBytes = 4_000

        session.finish()
        scheduler.advanceBy(ElevenLabsLiveSession.POST_COMMIT_WINDOW_MS + 500)
        assertNull(listener.outcome)
        sockets.last.queuedBytes = 0
        scheduler.advanceBy(ElevenLabsLiveSession.POST_COMMIT_WINDOW_MS + 100)

        assertEquals(LiveOutcome.Completed(""), listener.outcome)
    }

    @Test
    fun testStopWithoutTheCommitsAnswer_returnsOnlyCommittedSegments() {
        val session = started()
        session.append(pcm(100))
        sockets.last.serverSends(committed("First part."))
        sockets.last.serverSends(partial("unconfirmed tail"))

        session.finish()
        scheduler.advanceBy(ElevenLabsLiveSession.POST_COMMIT_WINDOW_MS)

        assertEquals(LiveOutcome.Completed("First part."), listener.outcome)
    }

    @Test
    fun testAuthError_failsAsInvalidKeyKeepingTheTextAndNeverReconnects() {
        started()
        sockets.last.serverSends(partial("so far"))

        sockets.last.serverSends("""{"message_type":"auth_error","error":"bad key"}""")

        assertEquals(LiveOutcome.Failed(DictationFailure.InvalidKey, "so far"), listener.outcome)
        assertEquals(1, sockets.opened.size)
    }

    @Test
    fun testWarningsSurvive_butTerminalServerErrorsEndTheSession() {
        started()
        sockets.last.serverSends("""{"message_type":"warning","warning":"slow down"}""")
        assertNull(listener.outcome)

        sockets.last.serverSends("""{"message_type":"rate_limited","error":"too many"}""")

        assertEquals(LiveOutcome.Failed(DictationFailure.TooManyRequests, ""), listener.outcome)
    }

    @Test
    fun testFailureBeforeSessionStarted_endsWithoutAnotherAttempt() {
        val session = session()
        session.connect("el-key")
        session.append(pcm(100))

        sockets.last.serverFails(httpStatus = 401)

        assertEquals(LiveOutcome.Failed(DictationFailure.InvalidKey, ""), listener.outcome)
        assertEquals(1, sockets.opened.size)
    }

    @Test
    fun testSlowSessionStarted_failsAtTheReadinessDeadline() {
        session().connect("el-key")
        sockets.last.serverOpen()

        scheduler.advanceBy(ElevenLabsLiveSession.READY_DEADLINE_MS)

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
        assertEquals(1, sockets.opened.size)
    }

    @Test
    fun testDropAfterTheCommit_failsKeepingTheText() {
        val session = started()
        session.append(pcm(100))
        sockets.last.serverSends(committed("Kept."))
        session.finish()

        sockets.last.serverFails()

        assertEquals(LiveOutcome.Failed(DictationFailure.Network, "Kept."), listener.outcome)
    }

    @Test
    fun testStopThatNeverStarts_endsWithinTheFinishDeadline() {
        val session = session()
        session.connect("el-key")
        sockets.last.serverOpen()
        session.append(pcm(100))

        session.finish()
        scheduler.advanceBy(8_000)

        assertEquals(LiveOutcome.Failed(DictationFailure.NetworkTimeout, ""), listener.outcome)
        assertTrue(sockets.last.texts.isEmpty())
    }

    private companion object {
        const val SCRIBE_V2 = "elevenlabs/scribe-v2-streaming"
        const val SCRIBE_V3 = "elevenlabs/scribe-v3-live-streaming"
        const val SESSION_STARTED = """{"message_type":"session_started","session_id":"s1"}"""
    }
}
