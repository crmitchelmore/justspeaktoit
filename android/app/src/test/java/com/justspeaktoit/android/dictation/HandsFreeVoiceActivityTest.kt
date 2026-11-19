package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.RepoSources
import com.justspeaktoit.android.cloud.WavFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

/** Hands-free voice activity (#1632): SpeakCore's energy detector, the pre-roll gate and its recorder. */
class HandsFreeVoiceActivityTest {
    @get:Rule val tmp = TemporaryFolder()

    private val audio = SyntheticAudio()
    private val sampleRate = WavFormat.SAMPLE_RATE

    private fun EnergyVoiceActivityDetector.feed(chunks: List<ShortArray>) = chunks.mapNotNull { process(it) }

    /** Feeds [chunks] and returns the index of the chunk that started speech, if any. */
    private fun HandsFreeGate.trigger(chunks: List<ShortArray>): Int? {
        chunks.forEachIndexed { index, chunk ->
            when (receive(chunk)) {
                HandsFreeGate.Event.SpeechStarted -> return index
                HandsFreeGate.Event.Overflow -> error("Unexpected overflow")
                null -> Unit
            }
        }
        return null
    }

    private class Collector : HandsFreeSink {
        val samples = mutableListOf<Short>()

        override fun write(samples: ShortArray, count: Int) {
            for (index in 0 until count) this.samples += samples[index]
        }
    }

    @Test
    fun testSilence_neverTriggersAndKeepsOnlyThePreRoll() {
        val gate = HandsFreeGate().apply { resumeListening() }

        assertNull(gate.trigger(audio.chunks(30.0)))
        assertEquals(HandsFreeGate.Phase.Listening, gate.phase)
        assertEquals(HandsFreePolicy.PRE_ROLL_SECONDS, gate.bufferedSeconds, 1e-9)
    }

    @Test
    fun testSpeech_triggersWithinTheStartBudgetAndEndsAfterTheReleaseHang() {
        val detector = EnergyVoiceActivityDetector()
        detector.feed(audio.chunks(1.0))
        val speech = detector.feed(audio.chunks(1.5, tone = SyntheticAudio.voice(0.1)))
        val quiet = detector.feed(audio.chunks(1.0))

        val first = speech.firstOrNull { it.speechDetected }
        assertNotNull(first)
        assertTrue(first!!.seconds - 1 <= HandsFreePolicy.SPEECH_START_BUDGET_SECONDS + 1e-9)
        assertTrue("Syllable dips must not end speech", speech.drop(3).all { it.speechDetected })
        // The release hang (0.25 s) carries speech over the first quiet chunks, then it ends.
        assertTrue(quiet[0].speechDetected && quiet[1].speechDetected)
        assertFalse(quiet[3].speechDetected)
        assertFalse(quiet.last().speechDetected)
    }

    @Test
    fun testShortClicks_doNotTriggerSpeech() {
        val detector = EnergyVoiceActivityDetector()
        detector.feed(audio.chunks(1.0))
        val updates = listOf(0.005, 0.02, 0.06).flatMap { click ->
            val start = audio.clock
            detector.feed(audio.chunks(1.0) { time -> if (time - start < click) 0.8 else 0.0 })
        }

        assertFalse(updates.any { it.speechDetected })
    }

    @Test
    fun testSpeechAsTheMicrophoneOpens_stillTriggers() {
        for (amplitude in listOf(0.1, 0.014)) {
            for (sensitivity in HandsFreeSensitivity.entries) {
                val detector = EnergyVoiceActivityDetector(VoiceActivityConfiguration.of(sensitivity))
                val steady = { time: Double -> amplitude * kotlin.math.sin(2 * Math.PI * 180 * time) }
                val first = SyntheticAudio().let { fresh ->
                    detector.feed(fresh.chunks(1.0, tone = steady)).firstOrNull { it.speechDetected }
                }

                assertNotNull("$sensitivity at $amplitude", first)
                assertTrue(
                    first!!.seconds <= detector.configuration.calibrationSeconds +
                        HandsFreePolicy.SPEECH_START_BUDGET_SECONDS + 1e-9,
                )
            }
        }
    }

    @Test
    fun testAttach_deliversThePreRollIncludingTheOnsetThenLiveAudio() {
        val gate = HandsFreeGate().apply { resumeListening() }
        assertNull(gate.trigger(audio.chunks(1.0)))
        val speechStartsAt = audio.clock
        val voice = audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))
        val triggeredAt = gate.trigger(voice)
        assertNotNull(triggeredAt)
        assertEquals(HandsFreeGate.Phase.Starting, gate.phase)

        // Audio arriving while the recording starts is kept too.
        val whileStarting = voice[triggeredAt!! + 1]
        assertNull(gate.receive(whileStarting))
        val sink = Collector()
        assertTrue(gate.attach(sink))
        val preRoll = (sampleRate * HandsFreePolicy.PRE_ROLL_SECONDS).toInt()
        assertEquals(preRoll + whileStarting.size, sink.samples.size)

        // The buffer reaches back before the voice began, so the first word is not clipped.
        val triggerEnds = speechStartsAt + (triggeredAt + 1) * 0.1
        val quietSamples = ((speechStartsAt - (triggerEnds - HandsFreePolicy.PRE_ROLL_SECONDS)) * sampleRate).toInt()
        assertTrue(quietSamples > 0)
        assertTrue(sink.samples.take(quietSamples).all { abs(it.toInt()) < 100 })
        assertTrue(sink.samples.drop(quietSamples).any { abs(it.toInt()) > 1_000 })

        val live = voice[triggeredAt + 2]
        assertNull(gate.receive(live))
        assertEquals(live.toList(), sink.samples.takeLast(live.size))
    }

    @Test
    fun testDetach_stopsWritingUntilListeningResumesAndSpeechStartsAgain() {
        val gate = HandsFreeGate().apply { resumeListening() }
        gate.trigger(audio.chunks(1.0))
        assertNotNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))
        val sink = Collector()
        gate.attach(sink)
        gate.detach(sink)
        val written = sink.samples.size

        assertEquals(HandsFreeGate.Phase.Suspended, gate.phase)
        assertNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))
        assertEquals(written, sink.samples.size)

        gate.resumeListening()
        assertNull(gate.trigger(audio.chunks(1.0)))
        assertNotNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))
    }

    @Test
    fun testStartingTooLong_overflowsAndCloses() {
        val gate = HandsFreeGate().apply { resumeListening() }
        gate.trigger(audio.chunks(1.0))
        assertNotNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))

        val events = audio.chunks(HandsFreePolicy.MAX_STARTING_SECONDS + 0.5).map { gate.receive(it) }

        assertEquals(HandsFreeGate.Event.Overflow, events.filterNotNull().single())
        assertEquals(HandsFreeGate.Phase.Closed, gate.phase)
        assertFalse(gate.attach(Collector()))
    }

    @Test
    fun testUtteranceRecorder_writesTheTriggeredAudioAsAWav() {
        val gate = HandsFreeGate().apply { resumeListening() }
        val file = tmp.newFile("utterance.wav")
        val levels = mutableListOf<Double>()
        val idle = HandsFreeUtteranceRecorder(file, gate, { levels += it.atSeconds }, {}, {})
        assertFalse("Nothing to record before speech", idle.start())
        assertFalse(file.exists())

        gate.trigger(audio.chunks(1.0))
        assertNotNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))
        val recorder = HandsFreeUtteranceRecorder(file, gate, { levels += it.atSeconds }, {}, {})
        assertTrue(recorder.start())
        audio.chunks(0.3).forEach { gate.receive(it) }
        val bytes = recorder.stop()
        audio.chunks(0.3).forEach { gate.receive(it) }

        val expected = ((HandsFreePolicy.PRE_ROLL_SECONDS + 0.3) * WavFormat.BYTES_PER_SECOND).toLong()
        assertEquals(expected, bytes)
        assertEquals(bytes, recorder.stop())
        assertEquals(WavFormat.HEADER_BYTES + bytes, file.length())
        assertEquals(bytes.toInt(), dataSize(file))
        assertEquals(0.8, levels.last(), 1e-9)
    }

    @Test
    fun testUtteranceRecorder_reportsTheLimit() {
        val gate = HandsFreeGate().apply { resumeListening() }
        gate.trigger(audio.chunks(1.0))
        assertNotNull(gate.trigger(audio.chunks(1.0, tone = SyntheticAudio.voice(0.1))))
        var limits = 0
        val recorder = HandsFreeUtteranceRecorder(tmp.newFile("limit.wav"), gate, {}, { limits++ }, {}, maxSeconds = 1)
        assertTrue(recorder.start())
        audio.chunks(1.0).forEach { gate.receive(it) }

        assertEquals(1, limits)
        assertEquals(WavFormat.BYTES_PER_SECOND.toLong(), recorder.stop())
    }

    @Test
    fun testThresholds_matchSpeakCore() {
        val detector = RepoSources.speakCore("Capture/HandsFreeVoiceActivity.swift")
        val policy = RepoSources.speakCore("Capture/HandsFreeDictation.swift")
        val number = "(-?[0-9.]+)"

        val defaults = VoiceActivityConfiguration(onsetMarginDb = 0.0, releaseMarginDb = 0.0, minimumOnsetLevelDb = 0.0)
        val kotlinDefaults = mapOf(
            "minimumSpeechSeconds" to defaults.minimumSpeechSeconds,
            "releaseHangSeconds" to defaults.releaseHangSeconds,
            "calibrationSeconds" to defaults.calibrationSeconds,
            "noiseFloorRiseSeconds" to defaults.noiseFloorRiseSeconds,
            "noiseFloorRiseWhileSpeakingSeconds" to defaults.noiseFloorRiseWhileSpeakingSeconds,
            "noiseFloorFallSeconds" to defaults.noiseFloorFallSeconds,
            "noiseFloorRiseLimitDBPerSecond" to defaults.noiseFloorRiseLimitDbPerSecond,
            "speechNoiseFloorRiseLimitDBPerSecond" to defaults.speechNoiseFloorRiseLimitDbPerSecond,
            "frameSeconds" to defaults.frameSeconds,
        )
        val swiftDefaults = Regex("""(\w+): Double = $number""").findAll(detector)
            .associate { it.groupValues[1] to it.groupValues[2].toDouble() }
        assertEquals(kotlinDefaults, swiftDefaults.filterKeys { it in kotlinDefaults })

        val sensitivities = Regex("""case \.(\w+):\s*self\.init\(([^)]*)\)""").findAll(detector).associate { match ->
            val arguments = Regex("""(\w+): $number""").findAll(match.groupValues[2])
                .associate { it.groupValues[1] to it.groupValues[2].toDouble() }
            match.groupValues[1] to arguments
        }
        assertEquals(HandsFreeSensitivity.entries.map { it.name.lowercase() }.toSet(), sensitivities.keys)
        for (sensitivity in HandsFreeSensitivity.entries) {
            val swift = sensitivities.getValue(sensitivity.name.lowercase())
            assertEquals(swift.getValue("onsetMarginDB"), sensitivity.onsetMarginDb, 0.0)
            assertEquals(swift.getValue("releaseMarginDB"), sensitivity.releaseMarginDb, 0.0)
            assertEquals(swift.getValue("minimumOnsetLevelDB"), sensitivity.minimumOnsetLevelDb, 0.0)
            assertEquals(
                swift["minimumSpeechSeconds"] ?: swiftDefaults.getValue("minimumSpeechSeconds"),
                sensitivity.minimumSpeechSeconds,
                0.0,
            )
        }

        fun constant(source: String, name: String) =
            Regex("""static let $name: Double = $number""").find(source)!!.groupValues[1].toDouble()
        assertEquals(constant(detector, "quietestSpeechAtOpenDB"), VoiceActivityConfiguration.QUIETEST_SPEECH_AT_OPEN_DB, 0.0)
        assertEquals(constant(detector, "silenceLevelDB"), EnergyVoiceActivityDetector.SILENCE_LEVEL_DB, 0.0)
        assertEquals(constant(policy, "preRollSeconds"), HandsFreePolicy.PRE_ROLL_SECONDS, 0.0)
        assertEquals(constant(policy, "speechStartBudgetSeconds"), HandsFreePolicy.SPEECH_START_BUDGET_SECONDS, 0.0)
    }

    private fun dataSize(file: File): Int =
        ByteBuffer.wrap(file.readBytes(), WavFormat.HEADER_BYTES - 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
}
