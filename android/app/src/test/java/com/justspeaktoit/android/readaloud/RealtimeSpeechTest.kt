package com.justspeaktoit.android.readaloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.util.Base64

class RealtimeSpeechTest {
    private val spec = checkNotNull(
        VoiceCatalog.parse(SettingsSearchAsset.locate("app/src/main/assets/${VoiceCatalog.ASSET}").readText()).realtime,
    )
    private val voice = spec.voices.first()

    /** Answers each sent frame with the scripted frames, in order. */
    private class FakeSocket(private val replies: List<List<String>>, private val refused: Int? = null) : RealtimeSocket {
        val sent = mutableListOf<String>()
        private val inbox = Channel<String>(Channel.UNLIMITED)
        var closed = false

        override suspend fun send(text: String) {
            replies.getOrNull(sent.size)?.forEach { inbox.send(it) }
            sent += text
        }

        override suspend fun receive(): String {
            refused?.let { throw RealtimeHandshakeRefused(it) }
            return inbox.tryReceive().getOrNull() ?: throw IOException("closed")
        }

        override fun close() {
            closed = true
        }
    }

    private fun audio(bytes: ByteArray) = JSONObject()
        .put("type", "response.output_audio.delta").put("delta", Base64.getEncoder().encodeToString(bytes)).toString()

    private fun transcript(text: String) = JSONObject()
        .put("type", "response.output_audio_transcript.done").put("transcript", text).toString()

    private fun done(status: String = "completed") =
        JSONObject().put("type", "response.done").put("response", JSONObject().put("status", status)).toString()

    private val updated = JSONObject().put("type", "session.updated").toString()

    private fun failureOf(block: suspend () -> Unit): ReadAloudFailure = runBlocking {
        try {
            block()
        } catch (error: ReadAloudException) {
            return@runBlocking error.failure
        }
        fail("expected a failure")
        error("unreachable")
    }

    @Test
    fun testSpeak_sendsVoiceAndTextAndReturnsTheAudio() = runBlocking {
        val socket = FakeSocket(listOf(listOf(updated), listOf(audio(byteArrayOf(1, 0, 2, 0)), transcript("Hello there."), done())))
        var opened: Pair<String, Map<String, String>>? = null
        val synthesizer = RealtimeSpeechSynthesizer(spec) { url, headers ->
            opened = url to headers
            socket
        }

        val session = synthesizer.open(voice, " secret ")
        val pcm = session.speak("Hello there")
        session.close()

        assertArrayEquals(byteArrayOf(1, 0, 2, 0), pcm.data)
        assertEquals(spec.sampleRate, pcm.sampleRate)
        assertEquals(spec.url, opened?.first)
        assertTrue(opened!!.second.values.any { it.contains("secret") && !it.contains("{key}") })
        assertTrue(socket.sent[0].contains("\"${voice.voice}\""))
        assertFalse(socket.sent[0].contains("{voice}"))
        assertTrue(socket.sent[1].contains("Hello there"))
        assertTrue(socket.closed)
    }

    @Test
    fun testSpeak_refusesAnAnswerThatIsNotAReading() {
        val socket = FakeSocket(listOf(listOf(updated), listOf(audio(byteArrayOf(1, 0)), transcript("Sure, I can help with that."), done())))
        val failure = failureOf {
            RealtimeSpeechSynthesizer(spec) { _, _ -> socket }.open(voice, "k").speak("Read this sentence")
        }
        assertEquals(ReadAloudFailure.NotAReading(spec.providerName), failure)
    }

    @Test
    fun testSpeak_reportsErrorsAndIncompleteResponses() {
        val error = JSONObject().put("type", "error").put("error", JSONObject().put("message", "bad voice")).toString()
        assertEquals(
            ReadAloudFailure.ServiceMessage(spec.providerName, "bad voice"),
            failureOf { RealtimeSpeechSynthesizer(spec) { _, _ -> FakeSocket(listOf(listOf(error))) }.open(voice, "k") },
        )
        val incomplete = FakeSocket(listOf(listOf(updated), listOf(done("incomplete"))))
        assertEquals(
            ReadAloudFailure.ServiceMessage(spec.providerName, "incomplete"),
            failureOf { RealtimeSpeechSynthesizer(spec) { _, _ -> incomplete }.open(voice, "k").speak("Hi") },
        )
    }

    @Test
    fun testOpen_mapsARefusedHandshakeAndClosesTheSocket() {
        val socket = FakeSocket(emptyList(), refused = 401)
        val failure = failureOf { RealtimeSpeechSynthesizer(spec) { _, _ -> socket }.open(voice, "k") }
        assertEquals(ReadAloudFailure.KeyRejected(spec.providerName), failure)
        assertTrue(socket.closed)
        assertEquals(
            ReadAloudFailure.MissingKey(spec.providerName),
            failureOf { RealtimeSpeechSynthesizer(spec) { _, _ -> socket }.open(voice, "  ") },
        )
    }

    @Test
    fun testFaithfulReading_allowsNumeralsReadAsWordsButNotAnswers() {
        val words = spec.spokenWordsPerNumeral
        assertTrue(RealtimeReading.isFaithful("Call me at 5pm.", "Call me at five p m.", words))
        assertTrue(RealtimeReading.isFaithful("Café au lait", "café au lait", words))
        assertFalse(RealtimeReading.isFaithful("Read this", "Read", words))
        assertFalse(RealtimeReading.isFaithful("Yes", "Yes and here is a long answer you did not ask for", words))
    }
}
