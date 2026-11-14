package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.WavFormat
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Deterministic 16-bit microphone audio in 0.1 s chunks, as SpeakCore's
 * `HandsFreeEnergyVoiceActivityTests` builds it: quiet room noise plus an optional tone.
 */
internal class SyntheticAudio(private val sampleRate: Int = WavFormat.SAMPLE_RATE) {
    private var state = 12_345u

    /** Seconds of audio produced so far. */
    var clock = 0.0
        private set

    fun chunks(seconds: Double, noiseAmplitude: Double = 0.001, tone: (Double) -> Double = { 0.0 }): List<ShortArray> {
        val chunkLength = sampleRate / 10
        var remaining = (seconds * sampleRate).roundToInt()
        val out = mutableListOf<ShortArray>()
        while (remaining > 0) {
            val count = minOf(chunkLength, remaining)
            out += ShortArray(count) { index ->
                val time = clock + index.toDouble() / sampleRate
                pcm(noise(noiseAmplitude) + tone(time))
            }
            clock += count.toDouble() / sampleRate
            remaining -= count
        }
        return out
    }

    private fun noise(amplitude: Double): Double {
        state = state * 1_664_525u + 1_013_904_223u
        return ((state shr 8).toDouble() / (1 shl 24) * 2 - 1) * amplitude
    }

    private fun pcm(value: Double): Short = (value * Short.MAX_VALUE).roundToInt().coerceIn(-32_768, 32_767).toShort()

    companion object {
        /** A 180 Hz voice with a 4 Hz syllable envelope that dips to 20%. */
        fun voice(amplitude: Double): (Double) -> Double = { time ->
            val envelope = 0.6 + 0.4 * sin(2 * PI * 4 * time)
            amplitude * envelope * sin(2 * PI * 180 * time)
        }
    }
}
