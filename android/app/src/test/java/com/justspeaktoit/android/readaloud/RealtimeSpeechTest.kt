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
        val statusless = JSONObject().put("type", "response.done").put("response", JSONObject()).toString()
        val unstated = FakeSocket(listOf(listOf(updated), listOf(statusless)))
        assertEquals(
            ReadAloudFailure.ServiceMessage(spec.providerName, "no status"),
            failureOf { RealtimeSpeechSynthesizer(spec) { _, _ -> unstated }.open(voice, "k").speak("Hi") },
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

    private fun faithful(expected: String, spoken: String) =
        RealtimeReading.isFaithful(expected, spoken, spec.spokenWordsPerNumeral, spec.spokenWordsPerSymbol)

    @Test
    fun testFaithfulReading_requiresEveryWordButToleratesPunctuationAndSpokenNumerals() {
        assertTrue(faithful("Hello, world!", "hello world"))
        assertTrue(faithful("The year is 2026.", "The year is two thousand and twenty six."))
        assertTrue(faithful("It costs 5 dollars.", "It costs five dollars."))
        assertTrue(faithful("Café au lait", "café au lait"))
        assertFalse(faithful("Do not open the door.", "Do open the door."))
        assertFalse(faithful("Is it raining?", "Is it raining? I can't check the weather, sorry."))
        assertFalse(faithful("Hello", ""))
    }

    @Test
    fun testFaithfulReading_rejectsAChangedNumberOrAnInsertedNegation() {
        assertFalse(faithful("Take 5 tablets", "Take six tablets"))
        assertFalse(faithful("Take 5 tablets", "Take 6 tablets"))
        assertFalse(faithful("Take 5 tablets", "Take no tablets"))
        assertFalse(faithful("Payment is approved", "Payment is not approved"))
        assertFalse(faithful("The year is 2026.", "The year is twenty twenty five."))
    }

    @Test
    fun testFaithfulReading_acceptsCommonReadingsOfNumbersAndSymbols() {
        assertTrue(faithful("The year is 2026.", "The year is twenty twenty-six."))
        assertTrue(faithful("The year is 2026.", "The year is 2026."))
        assertTrue(faithful("We sold 2,026 units.", "We sold two thousand and twenty-six units."))
        assertTrue(faithful("Add 3.5 cups", "Add three point five cups"))
        assertTrue(faithful("Meet at 10:30", "Meet at ten thirty"))
        assertTrue(faithful("100 times", "a hundred times"))
        assertTrue(faithful("It costs $5", "It costs five dollars"))
        assertTrue(faithful("Salt & pepper", "Salt and pepper"))
        assertTrue(faithful("Finish 1st", "Finish first"))
        assertTrue(faithful("Call me at 5pm.", "Call me at five p m."))
        assertTrue(faithful("Es kostet 5 Euro", "Es kostet fünf Euro"))
    }

    @Test
    fun testFaithfulReading_keepsASignADecimalPointAndAnOverflowingScale() {
        assertTrue(faithful("The balance is -5", "The balance is minus five"))
        assertTrue(faithful("The balance is -5", "The balance is -5"))
        assertFalse("A dropped minus sign changes the number", faithful("The balance is -5", "The balance is five"))
        assertTrue(faithful("Add 3.5 cups", "Add 3.5 cups"))
        assertTrue(faithful("Add 3.5 cups", "Add three dot five cups"))
        assertFalse("35 is not three point five", faithful("Add 35 cups", "Add three point five cups"))
        assertTrue(faithful("Add 3.5 cups", "Add three five cups"))
        assertFalse("A sign word is not a decimal point", faithful("Add 3.5 cups", "Add three minus five cups"))
        assertFalse("An operator word is not a decimal point", faithful("Add 3.5 cups", "Add three plus five cups"))
        assertFalse("A point word is not a minus", faithful("The balance is -5", "The balance is point five"))
        assertFalse(
            "A scale past the limit is refused before it can overflow",
            faithful("Pay 290448384 now", "Pay 18446744074 billion now"),
        )
        assertTrue(faithful("Cafe\u0301 au lait", "caf\u00e9 au lait"))
    }
}
