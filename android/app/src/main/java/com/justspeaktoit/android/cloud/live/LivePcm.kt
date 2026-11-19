package com.justspeaktoit.android.cloud.live

import java.net.URLEncoder

/**
 * Converts 16-bit little-endian mono PCM between rates by linear interpolation, keeping position and the
 * last sample across chunks so a stream resamples the same however it is split.
 */
class Pcm16Resampler(private val fromRate: Int, private val toRate: Int) {
    // The next output sample's position in input samples, scaled by toRate. -toRate is the previous chunk's last sample.
    private var position = 0L
    private var previous: Int? = null

    fun process(input: ByteArray): ByteArray {
        if (fromRate == toRate) return input
        val count = input.size / 2
        if (count == 0) return ByteArray(0)
        fun sample(index: Int): Int = if (index < 0) {
            previous ?: sample(0)
        } else {
            (input[index * 2].toInt() and 0xFF) or (input[index * 2 + 1].toInt() shl 8)
        }
        val out = ArrayList<Int>(count * toRate / fromRate + 2)
        var pos = position
        while (true) {
            val index = Math.floorDiv(pos, toRate.toLong()).toInt()
            val fraction = pos - index.toLong() * toRate
            if (index > count - 1 || (index == count - 1 && fraction != 0L)) break
            val value = if (fraction == 0L) {
                sample(index)
            } else {
                val a = sample(index)
                val b = sample(index + 1)
                (a + (b - a) * fraction / toRate).toInt()
            }
            out += value
            pos += fromRate
        }
        position = pos - count.toLong() * toRate
        previous = sample(count - 1)
        val bytes = ByteArray(out.size * 2)
        out.forEachIndexed { i, value ->
            bytes[i * 2] = value.toByte()
            bytes[i * 2 + 1] = (value shr 8).toByte()
        }
        return bytes
    }
}

/**
 * Cuts PCM into fixed frames. AssemblyAI rejects frames under 50 ms (close code 3007), so the last short
 * tail is padded with silence to [minimumTailBytes].
 */
class PcmFramer(private val frameBytes: Int, private val minimumTailBytes: Int) {
    private var held = ByteArray(0)

    fun push(pcm: ByteArray): List<ByteArray> {
        val data = held + pcm
        val frames = (0 until data.size / frameBytes).map { data.copyOfRange(it * frameBytes, (it + 1) * frameBytes) }
        held = data.copyOfRange(frames.size * frameBytes, data.size)
        return frames
    }

    fun finish(): List<ByteArray> {
        if (held.isEmpty()) return emptyList()
        val length = maxOf(held.size + held.size % 2, minimumTailBytes)
        val tail = held.copyOf(length)
        held = ByteArray(0)
        return listOf(tail)
    }
}

/** Vocabulary bounds from SpeakCore's `TranscriptionKeywordPolicy` and `AssemblyAIModels`. */
object LiveVocabulary {
    /** Trimmed, non-empty, at most [length] characters, case-insensitively unique, at most [count]. */
    fun bounded(words: List<String>, count: Int, length: Int): List<String> {
        val seen = HashSet<String>()
        return words.map { it.trim() }
            .filter { it.isNotEmpty() && it.codePointCount(0, it.length) <= length && seen.add(it.lowercase()) }
            .take(count)
    }

    /** Deepgram `keyterm`s: a 500-byte budget stays under its 500-token limit without a tokenizer. */
    fun deepgramKeyterms(words: List<String>): List<String> {
        var remaining = DEEPGRAM_MAX_BYTES
        return bounded(words, MAX_TERMS, MAX_TERM_LENGTH).filter { word ->
            val cost = word.toByteArray(Charsets.UTF_8).size + 1
            if (cost > remaining) return@filter false
            remaining -= cost
            true
        }
    }

    /** AssemblyAI `keyterms_prompt`: terms of at most 50 characters, at most 100 of them. */
    fun assemblyAIKeyterms(words: List<String>): List<String> = bounded(words, MAX_TERMS, ASSEMBLYAI_MAX_TERM_LENGTH)

    private const val DEEPGRAM_MAX_BYTES = 500
    private const val MAX_TERMS = 100
    private const val MAX_TERM_LENGTH = 100
    private const val ASSEMBLYAI_MAX_TERM_LENGTH = 50
}

internal fun queryString(items: List<Pair<String, String>>): String =
    items.joinToString("&") { (name, value) -> "${encode(name)}=${encode(value)}" }

private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
