package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadAloudControllerTest {
    private class FakeEngine(private val fault: Exception? = null) : ReadAloudEngine {
        val spoken = mutableListOf<String>()
        val finish = CompletableDeferred<ReadAloudFailure?>()
        var pauses = 0
        var resumes = 0
        var cancelled = false

        override suspend fun play(text: String, onAudible: () -> Unit) {
            spoken += text
            fault?.let { throw it }
            onAudible()
            try {
                finish.await()?.let { throw ReadAloudException(it) }
            } catch (error: kotlinx.coroutines.CancellationException) {
                cancelled = true
                throw error
            }
        }

        override fun pause() {
            pauses++
        }

        override fun resume() {
            resumes++
        }
    }

    private class FakeFocus(private val grant: Boolean = true) : ReadAloudFocus {
        var listener: ((FocusChange) -> Unit)? = null
        var requests = 0
        var abandons = 0

        override fun request(onChange: (FocusChange) -> Unit): Boolean {
            requests++
            if (grant) listener = onChange
            return grant
        }

        override fun abandon() {
            abandons++
        }
    }

    private val pronunciations = listOf(
        PronunciationEntry(PronunciationEntry.newId(), "SQL", "sequel", "sequel"),
    )

    @Test
    fun testSpeak_appliesPronunciationsAndFinishesIdle() = runBlocking {
        val engine = FakeEngine()
        val focus = FakeFocus()
        val chosen = mutableListOf<VoiceSelection>()
        val controller = ReadAloudController(this, { chosen += it; engine }, focus)

        controller.speak("Learn SQL today", VoiceSelection.Cloud("m|v"), pronunciations)
        assertEquals(ReadAloudPhase.Preparing, controller.state.value.phase)
        yield()

        assertEquals(listOf("Learn sequel today"), engine.spoken)
        assertEquals(ReadAloudPhase.Speaking, controller.state.value.phase)
        engine.finish.complete(null)
        yield()
        assertEquals(ReadAloudState(), controller.state.value)
        assertEquals(listOf<VoiceSelection>(VoiceSelection.Cloud("m|v")), chosen)
        assertEquals(1, focus.abandons)
    }

    @Test
    fun testFailure_isReportedWithoutTryingAnotherVoice() = runBlocking {
        val engine = FakeEngine()
        var built = 0
        val controller = ReadAloudController(this, { built++; engine }, FakeFocus())

        controller.speak("Hello", VoiceSelection.Cloud("m|v"), emptyList())
        yield()
        engine.finish.complete(ReadAloudFailure.RateLimited("Deepgram"))
        yield()

        assertEquals(ReadAloudState(failure = ReadAloudFailure.RateLimited("Deepgram")), controller.state.value)
        assertEquals(1, built)
        controller.dismissFailure()
        assertNull(controller.state.value.failure)
    }

    @Test
    fun testEngineFault_isShownAsPlaybackFailure() = runBlocking {
        val controller = ReadAloudController(this, { FakeEngine(IllegalStateException("boom")) }, FakeFocus())

        controller.speak("Hello", VoiceSelection.System(), emptyList())
        yield()

        assertEquals(ReadAloudFailure.PlaybackFailed, controller.state.value.failure)
        assertFalse(controller.state.value.active)
    }

    @Test
    fun testMissingKeyAndRefusedFocus_failBeforePlaying() = runBlocking {
        val focus = FakeFocus()
        val missing = ReadAloudController(this, { throw ReadAloudException(ReadAloudFailure.MissingKey("Groq")) }, focus)
        missing.speak("Hello", VoiceSelection.Cloud("m|v"), emptyList())
        assertEquals(ReadAloudFailure.MissingKey("Groq"), missing.state.value.failure)
        assertEquals(0, focus.requests)

        val engine = FakeEngine()
        val busy = ReadAloudController(this, { engine }, FakeFocus(grant = false))
        busy.speak("Hello", VoiceSelection.System(), emptyList())
        yield()
        assertEquals(ReadAloudFailure.AudioBusy, busy.state.value.failure)
        assertTrue(engine.spoken.isEmpty())
    }

    @Test
    fun testFocus_transientLossPausesAndRegainResumesOnlyThatPause() = runBlocking {
        val engine = FakeEngine()
        val focus = FakeFocus()
        val controller = ReadAloudController(this, { engine }, focus)
        controller.speak("Hello", VoiceSelection.System(), emptyList())
        yield()

        focus.listener!!(FocusChange.LostTransient)
        assertEquals(ReadAloudPhase.Paused, controller.state.value.phase)
        focus.listener!!(FocusChange.Gained)
        assertEquals(ReadAloudPhase.Speaking, controller.state.value.phase)
        assertEquals(1, engine.pauses)
        assertEquals(1, engine.resumes)

        controller.pause()
        focus.listener!!(FocusChange.LostTransient)
        focus.listener!!(FocusChange.Gained)
        assertEquals(ReadAloudPhase.Paused, controller.state.value.phase)
        controller.resume()
        assertEquals(ReadAloudPhase.Speaking, controller.state.value.phase)

        focus.listener!!(FocusChange.Lost)
        yield()
        assertEquals(ReadAloudState(), controller.state.value)
        assertTrue(engine.cancelled)
    }

    @Test
    fun testStop_cancelsWithoutFailure() = runBlocking {
        val engine = FakeEngine()
        val focus = FakeFocus()
        val controller = ReadAloudController(this, { engine }, focus)
        controller.speak("Hello", VoiceSelection.System(), emptyList())
        yield()

        controller.stop()
        yield()

        assertEquals(ReadAloudState(), controller.state.value)
        assertTrue(engine.cancelled)
        assertEquals(1, focus.abandons)
    }

    @Test
    fun testVoiceSelection_roundTripsAndDefaultsToSystem() {
        listOf(VoiceSelection.System(), VoiceSelection.System("en-gb-x-rjs-local"), VoiceSelection.Cloud("aura-2|aura-2-thalia-en"))
            .forEach { assertEquals(it, VoiceSelection.parse(it.encoded)) }
        assertEquals(VoiceSelection.System(), VoiceSelection.parse(null))
        assertEquals(VoiceSelection.System(), VoiceSelection.parse("cloud:"))
        assertEquals(VoiceSelection.System(), VoiceSelection.parse("unknown"))
    }
}

class CloudReadAloudEngineTest {
    private class RecordingOutput : PcmOutput {
        val played = mutableListOf<ByteArray>()
        var drained = false
        var stops = 0

        override suspend fun play(audio: PcmAudio) {
            played += audio.data
        }

        override suspend fun drain() {
            drained = true
        }

        override fun pause() = Unit

        override fun resume() = Unit

        override fun stop() {
            stops++
        }
    }

    private fun http(answer: (String) -> SpeechHttpResponse) = object : SpeechHttp {
        override suspend fun send(request: SpeechHttpRequest) = answer(request.url)
    }

    private val voice = CloudVoice(
        key = "m|v", id = "v", name = "V", label = "V", provider = "test", providerName = "Test", modelId = "m",
        credentialId = "test.apiKey", sampleRate = 24000, maxCharacters = 20, maxSegments = null,
        response = VoiceResponse.Wav,
        request = VoiceRequestTemplate("POST", "https://example.invalid/{text}", emptyMap(), null, null),
        dialogue = null,
    )

    @Test
    fun testPlay_speaksSegmentsInOrderAndReleasesOutput() = runBlocking {
        val output = RecordingOutput()
        var audible = 0
        val http = http { url ->
            val index = if (url.contains("One")) 1 else 2
            SpeechHttpResponse(200, CloudSpeechSynthesizerTest.wav(byteArrayOf(index.toByte(), 0)))
        }
        val engine = CloudReadAloudEngine(voice, "k", "en", CloudSpeechSynthesizer(http), output)

        engine.play("One short sentence. Another one here.") { audible++ }

        assertEquals(listOf(1, 2), output.played.map { it[0].toInt() })
        assertEquals(1, audible)
        assertTrue(output.drained)
        assertEquals(1, output.stops)
    }

    @Test
    fun testPlay_failureStopsOutputAndPropagates() = runBlocking {
        val output = RecordingOutput()
        val http = http { url ->
            if (url.contains("One")) {
                SpeechHttpResponse(200, CloudSpeechSynthesizerTest.wav(byteArrayOf(1, 0)))
            } else {
                SpeechHttpResponse(401, ByteArray(0))
            }
        }
        val engine = CloudReadAloudEngine(voice, "k", "en", CloudSpeechSynthesizer(http), output)

        val failure = try {
            engine.play("One short sentence. Another one here.") {}
            null
        } catch (error: ReadAloudException) {
            error.failure
        }

        assertEquals(ReadAloudFailure.KeyRejected("Test"), failure)
        assertFalse(output.drained)
        assertEquals(1, output.stops)
    }
}
