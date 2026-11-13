package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class OpenAIRealtimeLiveSessionTest {
    private val scheduler = ManualScheduler()
    private val sockets = FakeSockets()
    private val listener = RecordingListener()

    private fun session(catalogId: String = LIVE, prompt: String? = "Kubernetes") =
        OpenAIRealtimeLiveSession(liveModel(catalogId), "en", prompt, scheduler, sockets, listener)

    private fun ready(catalogId: String = LIVE): OpenAIRealtimeLiveSession = session(catalogId).also {
        it.connect("sk-test")
        sockets.last.serverOpen()
        sockets.last.serverSends(SESSION_UPDATED)
    }

    private fun appendedAudioBytes(socket: FakeSocket): List<Int> = socket.texts
        .map(::JSONObject)
        .filter { it.optString("type") == "input_audio_buffer.append" }
        .map { Base64.getDecoder().decode(it.getString("audio")).size }

    private fun delta(item: String, text: String) =
        """{"type":"conversation.item.input_audio_transcription.delta","item_id":"$item","delta":"$text"}"""

    private fun completed(item: String, text: String) =
        """{"type":"conversation.item.input_audio_transcription.completed","item_id":"$item","transcript":"$text"}"""

    @Test
    fun testOpen_sendsTheGaTranscriptionSessionUpdateWithoutTheBetaHeader() {
        session().connect("sk-test")
        val socket = sockets.last
        assertEquals("wss://api.openai.com/v1/realtime?intent=transcription", socket.request.url)
        assertEquals(mapOf("Authorization" to "Bearer sk-test"), socket.request.headers)

        socket.serverOpen()

        val update = JSONObject(socket.texts.single())
        assertEquals("session.update", update.getString("type"))
        val session = update.getJSONObject("session")
        assertEquals("transcription", session.getString("type"))
        val input = session.getJSONObject("audio").getJSONObject("input")
        assertEquals(24_000, input.getJSONObject("format").getInt("rate"))
        assertTrue(input.isNull("turn_detection"))
        val transcription = input.getJSONObject("transcription")
        assertEquals("gpt-live-transcribe", transcription.getString("model"))
        assertEquals("en", transcription.getJSONArray("languages").getString(0))
        assertEquals("Kubernetes", transcription.getString("prompt"))
    }

    @Test
    fun testWhisperSession_usesSingularLanguageAndNoPrompt() {
        val json = OpenAIRealtimeLiveSession.sessionUpdateJson(liveModel(WHISPER), "de", "Kubernetes")
        val transcription = JSONObject(json).getJSONObject("session").getJSONObject("audio")
            .getJSONObject("input").getJSONObject("transcription")

        assertEquals("de", transcription.getString("language"))
        assertFalse(transcription.has("languages"))
        assertFalse(transcription.has("prompt"))
    }

    @Test
    fun testAudioWaitsForSessionUpdated_andIsResampledTo24kHz() {
        val session = session()
        session.connect("sk-test")
        sockets.last.serverOpen()
        session.append(pcm(100))
        assertTrue(appendedAudioBytes(sockets.last).isEmpty())

        sockets.last.serverSends(SESSION_UPDATED)

        // 1,600 samples at 16 kHz become 2,399 at 24 kHz; the last waits for the next chunk.
        assertEquals(listOf(4_798), appendedAudioBytes(sockets.last))
    }

    @Test
    fun testDeltasAccumulate_andCompletedReplacesTheItem() {
        ready()

        sockets.last.serverSends(delta("a", "hel"))
        sockets.last.serverSends(delta("a", "lo"))
        sockets.last.serverSends(completed("a", "Hello."))
        sockets.last.serverSends(delta("a", " late"))
        sockets.last.serverSends(delta("b", "wor"))

        assertEquals(listOf("hel", "hello", "Hello.", "Hello. wor"), listener.partials)
    }

    @Test
    fun testStop_padsAShortBufferCommitsAndCompletesWithTheFinalItem() {
        val session = ready()
        session.append(pcm(20))
        sockets.last.serverSends(completed("a", "Earlier."))

        session.finish()
        val socket = sockets.last
        assertEquals(OpenAIRealtimeLiveSession.MINIMUM_COMMIT_BYTES, appendedAudioBytes(socket).sum())
        assertEquals("input_audio_buffer.commit", JSONObject(socket.texts.last()).getString("type"))

        socket.serverSends("""{"type":"input_audio_buffer.committed","item_id":"b"}""")
        socket.serverSends(delta("b", "fin"))
        assertNull(listener.outcome)
        socket.serverSends(completed("b", "Final."))

        assertEquals(LiveOutcome.Completed("Earlier. Final."), listener.outcome)
    }

    @Test
    fun testStopWithoutACompletedItem_endsAfterTheFinaliseBudgetWithTheDeltas() {
        val session = ready()
        session.append(pcm(200))
        sockets.last.serverSends(delta("a", "half heard"))

        session.finish()
        scheduler.advanceBy(499)
        assertNull(listener.outcome)
        scheduler.advanceBy(1)

        assertEquals(LiveOutcome.Completed("half heard"), listener.outcome)
    }

    @Test
    fun testUnrelatedErrors_areIgnored_butASessionConfigurationErrorEndsTheRun() {
        ready()
        sockets.last.serverSends(delta("a", "kept"))

        sockets.last.serverSends("""{"type":"error","error":{"message":"buffer too small","event_id":"other"}}""")
        sockets.last.serverSends("""{"type":"error","error":{"message":"no id"}}""")
        assertNull(listener.outcome)

        sockets.last.serverSends(
            """{"type":"error","error":{"event_id":"${OpenAIRealtimeLiveSession.SESSION_UPDATE_EVENT_ID}"}}""",
        )
        assertEquals(LiveOutcome.Failed(DictationFailure.Server, "kept"), listener.outcome)
    }

    @Test
    fun testANonTranscriptionSession_isRejected() {
        session().connect("sk-test")
        sockets.last.serverOpen()

        sockets.last.serverSends("""{"type":"session.updated","session":{"type":"realtime"}}""")

        assertEquals(LiveOutcome.Failed(DictationFailure.Server, ""), listener.outcome)
    }

    @Test
    fun testFailedFinalItem_failsKeepingEarlierText() {
        val session = ready()
        session.append(pcm(200))
        sockets.last.serverSends(completed("a", "Earlier."))
        session.finish()
        sockets.last.serverSends("""{"type":"input_audio_buffer.committed","item_id":"b"}""")

        sockets.last.serverSends("""{"type":"conversation.item.input_audio_transcription.failed","item_id":"b"}""")

        assertEquals(LiveOutcome.Failed(DictationFailure.Server, "Earlier."), listener.outcome)
    }

    private companion object {
        const val LIVE = "openai/gpt-live-transcribe-streaming"
        const val WHISPER = "openai/gpt-realtime-whisper-streaming"
        const val SESSION_UPDATED = """{"type":"session.updated","session":{"type":"transcription"}}"""
    }
}
