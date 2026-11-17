package com.justspeaktoit.android.readaloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64

class CloudSpeechSynthesizerTest {
    private val catalog = VoiceCatalog.parse(SettingsSearchAsset.locate("app/src/main/assets/${VoiceCatalog.ASSET}").readText())

    /** Answers every request with the next response and keeps what was sent. */
    private class FakeHttp(vararg responses: SpeechHttpResponse) : SpeechHttp {
        private val queue = ArrayDeque(responses.toList())
        val sent = mutableListOf<SpeechHttpRequest>()
        var unreachable = false

        override suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse {
            sent += request
            if (unreachable) throw IOException("offline")
            return queue.removeFirst()
        }
    }

    private fun voice(provider: String, dialogue: Boolean = false) =
        catalog.voices.first { it.provider == provider && (it.dialogue != null) == dialogue }

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
    fun testCatalog_parsesEveryExportedVoice() {
        assertTrue(catalog.voices.size > 50)
        assertEquals(catalog.voices.size, catalog.voices.map { it.key }.toSet().size)
        val providers = catalog.voices.map { it.provider }.toSet()
        assertTrue(providers.containsAll(listOf("azure", "deepgram", "elevenlabs", "google")))
        assertTrue(catalog.pronunciationDefaults.isNotEmpty())
        assertNull(PronunciationDictionary.validate(catalog.pronunciationDefaults))
        assertNotNull(catalog.voice(catalog.voices.first().key))
    }

    @Test
    fun testRequest_fillsKeyAndJsonTextWithoutLeakingTheKeyThroughText() = runBlocking {
        val http = FakeHttp(SpeechHttpResponse(200, wav(byteArrayOf(1, 0, 2, 0))))
        val voice = voice("deepgram")
        val synthesizer = CloudSpeechSynthesizer(http)

        val audio = synthesizer.synthesize(voice, CloudSpeechSynthesizer.Segment("say {key} \"now\"", false), " secret ", "en")

        val request = http.sent.single()
        assertEquals("Token secret", request.headers["Authorization"])
        assertEquals("say {key} \"now\"", JSONObject(String(request.body)).getString("text"))
        assertArrayEquals(byteArrayOf(1, 0, 2, 0), audio.data)
    }

    @Test
    fun testAzure_fillsRegionAndEscapesSsml() = runBlocking {
        val http = FakeHttp(SpeechHttpResponse(200, wav(byteArrayOf(0, 1))))

        CloudSpeechSynthesizer(http).synthesize(voice("azure"), CloudSpeechSynthesizer.Segment("a < b & 'c'", false), "k:westeurope", "en")

        val request = http.sent.single()
        assertEquals("https://westeurope.tts.speech.microsoft.com/cognitiveservices/v1", request.url)
        assertEquals("k", request.headers["Ocp-Apim-Subscription-Key"])
        assertTrue(String(request.body).contains("a &lt; b &amp; &apos;c&apos;"))
    }

    @Test
    fun testDialogue_fallsBackToTheVoiceModelOnlyForListedStatuses() = runBlocking {
        val voice = voice("elevenlabs", dialogue = true)
        val synthesizer = CloudSpeechSynthesizer(FakeHttp())
        val segment = synthesizer.plan(voice, "Hello there").single()
        assertTrue(segment.dialogue)

        val http = FakeHttp(SpeechHttpResponse(422, ByteArray(0)), SpeechHttpResponse(200, wav(byteArrayOf(5, 0))))
        CloudSpeechSynthesizer(http).synthesize(voice, segment, "key", "en")
        assertTrue(http.sent[0].url.contains("text-to-dialogue"))
        assertFalse(http.sent[1].url.contains("text-to-dialogue"))

        val refused = FakeHttp(SpeechHttpResponse(401, ByteArray(0)))
        assertEquals(
            ReadAloudFailure.KeyRejected("ElevenLabs"),
            failureOf { CloudSpeechSynthesizer(refused).synthesize(voice, segment, "key", "en") },
        )
        assertEquals(1, refused.sent.size)
    }

    @Test
    fun testFailures_mapStatusesAndNeverTryAnotherProvider() {
        val voice = voice("deepgram")
        val segment = CloudSpeechSynthesizer.Segment("hi", false)
        val cases = mapOf(
            403 to ReadAloudFailure.KeyRejected("Deepgram"),
            402 to ReadAloudFailure.OutOfCredit("Deepgram"),
            429 to ReadAloudFailure.RateLimited("Deepgram"),
            503 to ReadAloudFailure.ServiceError("Deepgram", 503),
        )
        cases.forEach { (status, expected) ->
            val http = FakeHttp(SpeechHttpResponse(status, ByteArray(0)))
            assertEquals(expected, failureOf { CloudSpeechSynthesizer(http).synthesize(voice, segment, "k", "en") })
            assertEquals(1, http.sent.size)
        }
        val offline = FakeHttp().apply { unreachable = true }
        assertEquals(
            ReadAloudFailure.Unreachable("Deepgram"),
            failureOf { CloudSpeechSynthesizer(offline).synthesize(voice, segment, "k", "en") },
        )
        assertEquals(
            ReadAloudFailure.MissingKey("Deepgram"),
            failureOf { CloudSpeechSynthesizer(FakeHttp()).synthesize(voice, segment, "  ", "en") },
        )
        val notAudio = FakeHttp(SpeechHttpResponse(200, "{}".toByteArray()))
        assertEquals(
            ReadAloudFailure.InvalidAudio("Deepgram"),
            failureOf { CloudSpeechSynthesizer(notAudio).synthesize(voice, segment, "k", "en") },
        )
    }

    @Test
    fun testGemini_retriesOneServerFaultAndDecodesInteractionAudio() = runBlocking {
        val pcm = byteArrayOf(9, 0, 8, 0)
        val body = """{"steps":[{"content":[{"type":"text"},{"type":"audio","data":"${Base64.getEncoder().encodeToString(pcm)}","sample_rate":16000}]}]}"""
        val http = FakeHttp(SpeechHttpResponse(500, ByteArray(0)), SpeechHttpResponse(200, body.toByteArray()))
        val voice = voice("google")

        val audio = CloudSpeechSynthesizer(http).synthesize(voice, CloudSpeechSynthesizer.Segment("hi", false), "k", "en")

        assertEquals(2, http.sent.size)
        assertEquals("k", http.sent[0].headers["x-goog-api-key"])
        assertEquals(16000, audio.sampleRate)
        assertArrayEquals(pcm, audio.data)
    }

    @Test
    fun testGemini_retriesOneAnswerWithoutAudioOrServerFaultLikeSpeakCore() = runBlocking {
        val pcm = byteArrayOf(9, 0, 8, 0)
        val audioBody = """{"steps":[{"content":[{"type":"audio","data":"${Base64.getEncoder().encodeToString(pcm)}"}]}]}"""
        val textOnly = """{"steps":[{"content":[{"type":"text","text":"Sure!"}]}]}""".toByteArray()
        val voice = voice("google")
        val segment = CloudSpeechSynthesizer.Segment("hi", false)

        val noAudioThenAudio = FakeHttp(SpeechHttpResponse(200, textOnly), SpeechHttpResponse(200, audioBody.toByteArray()))
        assertArrayEquals(pcm, CloudSpeechSynthesizer(noAudioThenAudio).synthesize(voice, segment, "k", "en").data)
        assertEquals(2, noAudioThenAudio.sent.size)

        val unavailableThenAudio = FakeHttp(SpeechHttpResponse(503, ByteArray(0)), SpeechHttpResponse(200, audioBody.toByteArray()))
        assertArrayEquals(pcm, CloudSpeechSynthesizer(unavailableThenAudio).synthesize(voice, segment, "k", "en").data)

        val neverAudio = FakeHttp(SpeechHttpResponse(200, textOnly), SpeechHttpResponse(200, textOnly))
        assertEquals(
            ReadAloudFailure.InvalidAudio(voice.providerName),
            failureOf { CloudSpeechSynthesizer(neverAudio).synthesize(voice, segment, "k", "en") },
        )
        assertEquals(2, neverAudio.sent.size)

        val refused = FakeHttp(SpeechHttpResponse(400, ByteArray(0)))
        assertEquals(
            ReadAloudFailure.ServiceError(voice.providerName, 400),
            failureOf { CloudSpeechSynthesizer(refused).synthesize(voice, segment, "k", "en") },
        )
        assertEquals(1, refused.sent.size)
    }

    @Test
    fun testAudio_isCutToWholeFramesSoTheSpeakerNeverStalls() = runBlocking {
        val voice = voice("deepgram")
        val segment = CloudSpeechSynthesizer.Segment("hi", false)

        val stereo = FakeHttp(SpeechHttpResponse(200, wav(byteArrayOf(1, 0, 2, 0, 3, 0), channels = 2)))
        val audio = CloudSpeechSynthesizer(stereo).synthesize(voice, segment, "k", "en")
        assertEquals(2, audio.channels)
        assertArrayEquals(byteArrayOf(1, 0, 2, 0), audio.data)

        val partialFrame = FakeHttp(SpeechHttpResponse(200, wav(byteArrayOf(1, 0), channels = 2)))
        assertEquals(
            ReadAloudFailure.InvalidAudio("Deepgram"),
            failureOf { CloudSpeechSynthesizer(partialFrame).synthesize(voice, segment, "k", "en") },
        )
    }

    @Test
    fun testPlan_splitsLongTextAndRefusesTooManySegments() {
        val voice = voice("deepgram").copy(maxCharacters = 20, maxSegments = 2)
        val synthesizer = CloudSpeechSynthesizer(FakeHttp())

        assertEquals(2, synthesizer.plan(voice, "One short sentence. Another one here.").size)
        assertTrue(synthesizer.plan(voice, "   ").isEmpty())
        try {
            synthesizer.plan(voice, "One sentence here. Two sentence here. Three sentence here.")
            fail("expected TooLong")
        } catch (error: ReadAloudException) {
            assertEquals(ReadAloudFailure.TooLong("Deepgram"), error.failure)
        }
    }

    @Test
    fun testPlan_emojiAtTheGroqLimitStaysWhole() {
        val voice = voice("groq")
        val text = "a".repeat(voice.maxCharacters - 1) + "\uD83D\uDE00" + "b".repeat(20)

        val segments = CloudSpeechSynthesizer(FakeHttp()).plan(voice, text).map { it.text }

        assertEquals(text, segments.joinToString(""))
        assertTrue(segments.all { it.length <= voice.maxCharacters })
        for (segment in segments) {
            assertFalse(segment.first().isLowSurrogate())
            assertFalse(segment.last().isHighSurrogate())
        }
    }

    @Test
    fun testWav_finiteDataLongerThanTheBodyIsInvalidAudio() = runBlocking {
        val truncated = wav(byteArrayOf(1, 0, 2, 0), dataSize = 4000)
        assertNull(WavAudio.parse(truncated))

        val http = FakeHttp(SpeechHttpResponse(200, truncated))
        val segment = CloudSpeechSynthesizer.Segment("hi", false)
        assertEquals(
            ReadAloudFailure.InvalidAudio("Deepgram"),
            failureOf { CloudSpeechSynthesizer(http).synthesize(voice("deepgram"), segment, "k", "en") },
        )
        for (sentinel in listOf(0, 0x7FFF0000)) {
            assertArrayEquals(byteArrayOf(1, 0, 2, 0), WavAudio.parse(wav(byteArrayOf(1, 0, 2, 0), dataSize = sentinel))!!.data)
        }
    }

    @Test
    fun testOversizedResponse_isInvalidAudioNotUnreachable() {
        val http = object : SpeechHttp {
            override suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse = throw SpeechResponseTooLarge(1)
        }
        val segment = CloudSpeechSynthesizer.Segment("hi", false)

        assertEquals(
            ReadAloudFailure.InvalidAudio("Deepgram"),
            failureOf { CloudSpeechSynthesizer(http).synthesize(voice("deepgram"), segment, "k", "en") },
        )
    }

    @Test
    fun testWav_readsStreamedSizesAndRejectsOtherFormats() {
        val streamed = wav(byteArrayOf(1, 2, 3, 4), dataSize = -1)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), WavAudio.parse(streamed)!!.data)
        assertEquals(24000, WavAudio.parse(streamed)!!.sampleRate)
        assertNull(WavAudio.parse(wav(byteArrayOf(1, 2), bits = 8)))
        assertNull(WavAudio.parse("RIFF....WAVE".toByteArray()))
        assertNull(WavAudio.parse(ByteArray(4)))
    }

    companion object {
        /** A WAV, mono by default; [dataSize] of -1 writes 0xFFFFFFFF as a streamed response does. */
        fun wav(
            pcm: ByteArray,
            sampleRate: Int = 24000,
            bits: Int = 16,
            dataSize: Int = pcm.size,
            channels: Int = 1,
        ): ByteArray =
            ByteBuffer.allocate(44 + pcm.size).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray())
                putInt(36 + pcm.size)
                put("WAVE".toByteArray())
                put("fmt ".toByteArray())
                putInt(16)
                putShort(1)
                putShort(channels.toShort())
                putInt(sampleRate)
                putInt(sampleRate * channels * bits / 8)
                putShort((channels * bits / 8).toShort())
                putShort(bits.toShort())
                put("data".toByteArray())
                putInt(dataSize)
                put(pcm)
            }.array()
    }
}
