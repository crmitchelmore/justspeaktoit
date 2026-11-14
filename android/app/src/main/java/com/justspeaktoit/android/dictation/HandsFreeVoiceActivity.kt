package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.WavFormat
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** SpeakCore's `HandsFreeDictationPolicy` timings that Android uses. */
internal object HandsFreePolicy {
    /** Audio kept from before speech was detected, so the first word is never clipped. */
    const val PRE_ROLL_SECONDS = 0.5

    /** Speech must be reported within this long of starting. */
    const val SPEECH_START_BUDGET_SECONDS = 0.3

    /** Audio buffered while a triggered recording starts, as `DesktopHandsFreeAudio` bounds it. Overflow disarms. */
    const val MAX_STARTING_SECONDS = 3.0
}

/**
 * SpeakCore's `AppleSpeechDetectorSensitivity`: how far above the room's noise floor speech must rise.
 * Hands-free uses [Medium], the shared default.
 */
internal enum class HandsFreeSensitivity(
    val onsetMarginDb: Double,
    val releaseMarginDb: Double,
    val minimumOnsetLevelDb: Double,
    val minimumSpeechSeconds: Double,
) {
    Low(onsetMarginDb = 15.0, releaseMarginDb = 9.0, minimumOnsetLevelDb = -50.0, minimumSpeechSeconds = 0.16),
    Medium(onsetMarginDb = 11.0, releaseMarginDb = 6.0, minimumOnsetLevelDb = -55.0, minimumSpeechSeconds = 0.12),
    High(onsetMarginDb = 8.0, releaseMarginDb = 4.0, minimumOnsetLevelDb = -62.0, minimumSpeechSeconds = 0.08),
}

/** SpeakCore's `HandsFreeEnergyVoiceActivityDetector.Configuration`, with the same defaults. */
internal data class VoiceActivityConfiguration(
    val onsetMarginDb: Double,
    val releaseMarginDb: Double,
    val minimumOnsetLevelDb: Double,
    val minimumSpeechSeconds: Double = 0.12,
    val releaseHangSeconds: Double = 0.25,
    val calibrationSeconds: Double = 0.2,
    val maximumCalibratedNoiseFloorDb: Double = QUIETEST_SPEECH_AT_OPEN_DB - onsetMarginDb,
    val noiseFloorRiseSeconds: Double = 4.0,
    val noiseFloorRiseWhileSpeakingSeconds: Double = 8.0,
    val noiseFloorFallSeconds: Double = 0.15,
    val noiseFloorRiseLimitDbPerSecond: Double = 3.0,
    val speechNoiseFloorRiseLimitDbPerSecond: Double = 1.0,
    val frameSeconds: Double = 0.02,
) {
    companion object {
        /** Steady speech at least this loud as the microphone opens still triggers. */
        const val QUIETEST_SPEECH_AT_OPEN_DB = -42.0

        fun of(sensitivity: HandsFreeSensitivity) = VoiceActivityConfiguration(
            onsetMarginDb = sensitivity.onsetMarginDb,
            releaseMarginDb = sensitivity.releaseMarginDb,
            minimumOnsetLevelDb = sensitivity.minimumOnsetLevelDb,
            minimumSpeechSeconds = sensitivity.minimumSpeechSeconds,
        )
    }
}

/**
 * A port of SpeakCore's `HandsFreeEnergyVoiceActivityDetector`: energy-based voice activity with
 * hysteresis, a minimum speech duration and an adaptive noise floor. It sees only signal power; nothing
 * is recognised or sent anywhere while it listens. Not thread-safe; [HandsFreeGate] serialises it.
 */
internal class EnergyVoiceActivityDetector(
    val configuration: VoiceActivityConfiguration = VoiceActivityConfiguration.of(HandsFreeSensitivity.Medium),
) {
    /** One report: whether speech was active at any point in the samples, and the timeline's end. */
    data class Update(val speechDetected: Boolean, val seconds: Double)

    private var speaking = false
    private var candidateSeconds = 0.0
    private var belowReleaseSeconds = 0.0
    private var noiseFloorDb: Double? = null
    private var calibratedSeconds = 0.0
    private var timelineSeconds = 0.0
    private var pendingSumOfSquares = 0.0
    private var pendingCount = 0

    /** The noise-floor estimate in dBFS, or null before any audio. */
    val estimatedNoiseFloorDb: Double? get() = noiseFloorDb

    /** Feeds 16-bit PCM and returns one report covering it, or null when no frame completed. */
    fun process(samples: ShortArray, count: Int = samples.size, sampleRate: Int = WavFormat.SAMPLE_RATE): Update? {
        if (sampleRate <= 0) return null
        val frameLength = max(1, (sampleRate * configuration.frameSeconds).roundToInt())
        val frameDuration = frameLength.toDouble() / sampleRate
        var completedFrame = false
        var speechSeen = false
        for (index in 0 until min(count, samples.size)) {
            val value = samples[index] / FULL_SCALE
            pendingSumOfSquares += value * value
            pendingCount += 1
            if (pendingCount < frameLength) continue
            val meanSquare = pendingSumOfSquares / pendingCount
            pendingSumOfSquares = 0.0
            pendingCount = 0
            observeFrame(levelDb(meanSquare), frameDuration)
            completedFrame = true
            speechSeen = speechSeen || speaking
        }
        return if (completedFrame) Update(speechSeen, timelineSeconds) else null
    }

    /** Forgets the utterance in progress but keeps the learned noise floor and timeline. */
    fun resetSpeech() {
        speaking = false
        candidateSeconds = 0.0
        belowReleaseSeconds = 0.0
    }

    private fun observeFrame(level: Double, duration: Double) {
        timelineSeconds += duration
        val floor = noiseFloorDb
        if (floor == null) {
            noiseFloorDb = min(level, configuration.maximumCalibratedNoiseFloorDb)
            calibratedSeconds = duration
            return
        }
        if (calibratedSeconds < configuration.calibrationSeconds) {
            // The quietest opening frames seed the floor before any speech can be reported.
            noiseFloorDb = min(floor, level)
            calibratedSeconds += duration
            return
        }
        val onset = max(floor + configuration.onsetMarginDb, configuration.minimumOnsetLevelDb)
        val release = max(
            floor + configuration.releaseMarginDb,
            configuration.minimumOnsetLevelDb - (configuration.onsetMarginDb - configuration.releaseMarginDb),
        )
        if (speaking) {
            if (level < release) {
                belowReleaseSeconds += duration
                if (belowReleaseSeconds >= configuration.releaseHangSeconds) {
                    speaking = false
                    belowReleaseSeconds = 0.0
                }
            } else {
                belowReleaseSeconds = 0.0
            }
        } else if (level >= onset || (candidateSeconds > 0 && level >= release)) {
            candidateSeconds += duration
            if (candidateSeconds >= configuration.minimumSpeechSeconds) {
                speaking = true
                candidateSeconds = 0.0
                belowReleaseSeconds = 0.0
            }
        } else {
            candidateSeconds = 0.0
        }
        updateNoiseFloor(floor, level, duration)
    }

    private fun updateNoiseFloor(floor: Double, level: Double, duration: Double) {
        val timeConstant: Double
        val maximumRise: Double
        if (level < floor) {
            timeConstant = configuration.noiseFloorFallSeconds
            maximumRise = 0.0
        } else if (speaking || candidateSeconds > 0) {
            timeConstant = configuration.noiseFloorRiseWhileSpeakingSeconds
            maximumRise = configuration.speechNoiseFloorRiseLimitDbPerSecond * duration
        } else {
            timeConstant = configuration.noiseFloorRiseSeconds
            maximumRise = configuration.noiseFloorRiseLimitDbPerSecond * duration
        }
        val weight = 1 - exp(-duration / max(timeConstant, duration))
        val step = (level - floor) * weight
        noiseFloorDb = floor + if (step > 0) min(step, maximumRise) else step
    }

    companion object {
        /** Below this a frame counts as digital silence. */
        const val SILENCE_LEVEL_DB = -100.0
        private const val FULL_SCALE = 32_768.0

        fun levelDb(meanSquare: Double): Double =
            if (meanSquare > 0) max(SILENCE_LEVEL_DB, 10 * log10(meanSquare)) else SILENCE_LEVEL_DB
    }
}

/** Receives a triggered utterance's audio, pre-roll first. Called with [HandsFreeGate]'s lock held. */
internal fun interface HandsFreeSink {
    fun write(samples: ShortArray, count: Int)
}

/**
 * The hands-free listening gate, as `DesktopHandsFreeAudio` runs it, fed every microphone chunk on the
 * capture thread. While [Phase.Listening] it keeps the last [HandsFreePolicy.PRE_ROLL_SECONDS] of
 * audio and runs [EnergyVoiceActivityDetector]; speech moves it to [Phase.Starting], which keeps
 * buffering (up to [HandsFreePolicy.MAX_STARTING_SECONDS]) until a recording [attach]es. The recording
 * then receives the pre-roll and everything after it, until it [detach]es. Quiet audio never reaches a
 * file. Thread-safe.
 */
internal class HandsFreeGate(
    private val detector: EnergyVoiceActivityDetector = EnergyVoiceActivityDetector(),
    private val sampleRate: Int = WavFormat.SAMPLE_RATE,
) {
    enum class Phase { Suspended, Listening, Starting, Recording, Closed }

    enum class Event {
        /** Speech crossed the threshold: start a recording and [attach] it. */
        SpeechStarted,

        /** A triggered recording never attached and the bounded buffer filled, so the gate closed. */
        Overflow,
    }

    private val buffered = ArrayDeque<ShortArray>()
    private var bufferedSamples = 0
    private var sink: HandsFreeSink? = null
    private val preRollSamples = (sampleRate * HandsFreePolicy.PRE_ROLL_SECONDS).roundToInt()
    private val maxStartingSamples = (sampleRate * HandsFreePolicy.MAX_STARTING_SECONDS).roundToInt()

    @get:Synchronized
    var phase = Phase.Suspended
        private set

    /** Audio held now: the pre-roll while listening, or the pre-roll and what followed while starting. */
    @get:Synchronized
    val bufferedSeconds: Double get() = bufferedSamples.toDouble() / sampleRate

    /** Feeds one microphone chunk; returns what the owner must act on, if anything. */
    @Synchronized
    fun receive(samples: ShortArray, count: Int = samples.size): Event? {
        val length = min(count, samples.size)
        if (length <= 0) return null
        return when (phase) {
            Phase.Closed, Phase.Suspended -> null
            Phase.Recording -> {
                sink?.write(samples, length)
                null
            }
            Phase.Starting -> {
                if (bufferedSamples + length > maxStartingSamples) {
                    phase = Phase.Closed
                    clear()
                    Event.Overflow
                } else {
                    append(samples.copyOf(length))
                    null
                }
            }
            Phase.Listening -> {
                append(samples.copyOf(length))
                trimToPreRoll()
                if (detector.process(samples, length, sampleRate)?.speechDetected == true) {
                    phase = Phase.Starting
                    Event.SpeechStarted
                } else {
                    null
                }
            }
        }
    }

    /**
     * Hands the buffered audio, pre-roll first, to [target] and streams to it from then on. Returns
     * false, writing nothing, unless speech has just started.
     */
    @Synchronized
    fun attach(target: HandsFreeSink): Boolean {
        if (phase != Phase.Starting) return false
        buffered.forEach { target.write(it, it.size) }
        clear()
        sink = target
        phase = Phase.Recording
        return true
    }

    /** Stops streaming to [target]; once this returns it receives nothing more. Listening stays suspended. */
    @Synchronized
    fun detach(target: HandsFreeSink) {
        if (sink !== target) return
        sink = null
        if (phase == Phase.Recording) phase = Phase.Suspended
    }

    /** Listens for the next utterance, keeping the learned noise floor. */
    @Synchronized
    fun resumeListening() {
        if (phase == Phase.Closed) return
        sink = null
        clear()
        detector.resetSpeech()
        phase = Phase.Listening
    }

    @Synchronized
    fun close() {
        phase = Phase.Closed
        sink = null
        clear()
    }

    private fun append(chunk: ShortArray) {
        buffered.addLast(chunk)
        bufferedSamples += chunk.size
    }

    private fun trimToPreRoll() {
        while (bufferedSamples > preRollSamples) {
            val first = buffered.removeFirst()
            val excess = bufferedSamples - preRollSamples
            if (excess >= first.size) {
                bufferedSamples -= first.size
            } else {
                buffered.addFirst(first.copyOfRange(excess, first.size))
                bufferedSamples -= excess
            }
        }
    }

    private fun clear() {
        buffered.clear()
        bufferedSamples = 0
    }
}
