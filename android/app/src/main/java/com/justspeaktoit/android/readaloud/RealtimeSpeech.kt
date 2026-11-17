package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Base64

/** A WebSocket carrying text frames, so tests can answer with fakes. */
interface RealtimeSocket {
    /** Throws IOException when the frame cannot be sent. */
    suspend fun send(text: String)

    /** The next frame; throws IOException when the socket fails or closes before the reading ends. */
    suspend fun receive(): String

    fun close()
}

/** Opens a WebSocket; a refused handshake surfaces as [RealtimeHandshakeRefused] from the first receive. */
fun interface RealtimeConnector {
    fun open(url: String, headers: Map<String, String>): RealtimeSocket
}

/** The server answered the WebSocket upgrade with an HTTP [status]. */
class RealtimeHandshakeRefused(val status: Int) : IOException("WebSocket upgrade refused with HTTP $status")

/**
 * Reads text with OpenAI Realtime, as SpeakCore's `OpenAIRealtimeSpeechSynthesizer` does: one session
 * per reading, one out-of-band response per chunk, and a response whose own transcript is not a
 * verbatim reading of the chunk is refused rather than played.
 */
class RealtimeSpeechSynthesizer(private val spec: RealtimeSpeechSpec, private val connector: RealtimeConnector) {
    private val provider get() = spec.providerName

    /** A connected session speaking with [voice]; close it when the reading ends. */
    suspend fun open(voice: RealtimeVoice, credential: String): Session {
        val key = credential.trim()
        if (key.isEmpty()) throw ReadAloudException(ReadAloudFailure.MissingKey(provider))
        val socket = connector.open(spec.url, spec.headers.mapValues { it.value.replace(KEY, key) })
        try {
            timed {
                send(socket, filled(spec.sessionUpdate, VOICE, voice.voice).toString())
                while (true) {
                    val event = event(socket)
                    when (event.optString("type")) {
                        "session.updated" -> break
                        "error" -> throw serviceMessage(event)
                    }
                }
            }
        } catch (error: Throwable) {
            socket.close()
            throw error
        }
        return Session(socket)
    }

    inner class Session internal constructor(private val socket: RealtimeSocket) {
        /** The audio of [chunk], once its transcript shows it was read verbatim. */
        suspend fun speak(chunk: String): PcmAudio = timed {
            send(socket, filled(spec.responseCreate, TEXT, chunk).toString())
            val audio = ByteArrayOutputStream()
            val transcript = StringBuilder()
            while (true) {
                val event = event(socket)
                when (event.optString("type")) {
                    "response.output_audio.delta" -> audio.write(decode(event.optString("delta")))
                    "response.output_audio_transcript.done" -> transcript.append(event.optString("transcript"))
                    "error" -> throw serviceMessage(event)
                    "response.done" -> {
                        val response = event.optJSONObject("response")
                        val status = response?.optString("status")?.takeIf { it.isNotEmpty() } ?: COMPLETED
                        if (status != COMPLETED) {
                            val details = response?.optJSONObject("status_details")
                            val reason = details?.optJSONObject("error")?.optString("message")?.takeIf { it.isNotEmpty() }
                                ?: details?.optString("reason")?.takeIf { it.isNotEmpty() }
                            throw ReadAloudException(
                                ReadAloudFailure.ServiceMessage(provider, listOfNotNull(status, reason).joinToString(": ")),
                            )
                        }
                        break
                    }
                }
            }
            if (!RealtimeReading.isFaithful(
                    chunk, transcript.toString(), spec.spokenWordsPerNumeral, spec.spokenWordsPerSymbol,
                )) {
                throw ReadAloudException(ReadAloudFailure.NotAReading(provider))
            }
            val pcm = audio.toByteArray()
            if (pcm.size < 2) throw ReadAloudException(ReadAloudFailure.InvalidAudio(provider))
            PcmAudio(spec.sampleRate, 1, if (pcm.size % 2 == 0) pcm else pcm.copyOf(pcm.size - 1))
        }

        fun close() = socket.close()
    }

    private suspend fun <T> timed(block: suspend () -> T): T = try {
        withTimeout(spec.responseTimeoutSeconds * MILLIS) { block() }
    } catch (_: TimeoutCancellationException) {
        throw ReadAloudException(ReadAloudFailure.TimedOut(provider))
    }

    private suspend fun send(socket: RealtimeSocket, text: String) = try {
        socket.send(text)
    } catch (error: IOException) {
        throw transportFailure(error)
    }

    private suspend fun event(socket: RealtimeSocket): JSONObject {
        val frame = try {
            socket.receive()
        } catch (error: IOException) {
            throw transportFailure(error)
        }
        return try {
            JSONObject(frame)
        } catch (_: JSONException) {
            JSONObject()
        }
    }

    private fun transportFailure(error: IOException): ReadAloudException {
        val status = (error as? RealtimeHandshakeRefused)?.status
        return ReadAloudException(
            when (status) {
                null -> ReadAloudFailure.Unreachable(provider)
                401, 403 -> ReadAloudFailure.KeyRejected(provider)
                402 -> ReadAloudFailure.OutOfCredit(provider)
                429 -> ReadAloudFailure.RateLimited(provider)
                else -> ReadAloudFailure.ServiceError(provider, status)
            },
        )
    }

    private fun serviceMessage(event: JSONObject) = ReadAloudException(
        ReadAloudFailure.ServiceMessage(
            provider,
            event.optJSONObject("error")?.optString("message")?.takeIf { it.isNotEmpty() } ?: UNKNOWN_ERROR,
        ),
    )

    private fun decode(delta: String): ByteArray = try {
        Base64.getDecoder().decode(delta)
    } catch (_: IllegalArgumentException) {
        throw ReadAloudException(ReadAloudFailure.InvalidAudio(provider))
    }

    private companion object {
        const val KEY = "{key}"
        const val TEXT = "{text}"
        const val VOICE = "{voice}"
        const val COMPLETED = "completed"
        const val UNKNOWN_ERROR = "Unknown OpenAI error"
        const val MILLIS = 1000L

        /** A copy of [value] with [placeholder] replaced in its string values only, so text stays text. */
        fun filled(value: Any?, placeholder: String, replacement: String): Any? = when (value) {
            is String -> if (value == placeholder) replacement else value.replace(placeholder, replacement)
            is JSONObject -> JSONObject().also { copy ->
                value.keys().forEach { name -> copy.put(name, filled(value.get(name), placeholder, replacement)) }
            }
            is JSONArray -> JSONArray().also { copy ->
                for (index in 0 until value.length()) copy.put(filled(value.get(index), placeholder, replacement))
            }
            else -> value
        }
    }
}

/**
 * SpeakCore's `RealtimeReadingCheck`; change both. The input is aligned with the transcript in order:
 * every word must be spoken; an all-digit numeral must be read as the same digits, as digits or English
 * number words, or (with neither) as up to `perNumeral` words of another language, never a negation;
 * a token mixing letters and digits is that bounded slot; and unmatched spoken words are allowed only
 * for symbols read aloud, `perSymbol` each.
 */
object RealtimeReading {
    /** Longer digit runs are not parsed as numbers; they become bounded slots. */
    private const val MAX_NUMERAL_DIGITS = 15

    private sealed interface Token {
        data class Word(val text: String) : Token
        data class Number(val digits: String) : Token
        data object Mixed : Token
    }

    fun isFaithful(expected: String, spoken: String, perNumeral: Int, perSymbol: Int): Boolean {
        val tokens = words(expected).map(::token)
        val heard = words(spoken)
        val budget = symbolCount(expected) * perSymbol
        val best = Array(tokens.size + 1) { IntArray(heard.size + 1) { Int.MAX_VALUE } }
        best[0][0] = 0
        for (index in 0..tokens.size) {
            for (position in 0..heard.size) {
                val cost = best[index][position]
                if (cost > budget) continue
                if (position < heard.size) best[index][position + 1] = minOf(best[index][position + 1], cost + 1)
                if (index == tokens.size) continue
                for (end in slotEnds(tokens[index], heard, position, perNumeral)) {
                    best[index + 1][end] = minOf(best[index + 1][end], cost)
                }
            }
        }
        return best[tokens.size][heard.size] <= budget
    }

    private fun slotEnds(token: Token, heard: List<String>, start: Int, perNumeral: Int): List<Int> {
        if (token is Token.Word) return if (start < heard.size && heard[start] == token.text) listOf(start + 1) else emptyList()
        val longest = minOf(heard.size, start + perNumeral)
        return (start + 1..longest).filter { accepts(token, heard.subList(start, it)) }
    }

    private fun accepts(token: Token, heard: List<String>): Boolean {
        if (heard.any { it in NEGATIONS }) return false
        if (token !is Token.Number) return true
        if (heard.none { isDigits(it) || NumberWords.value(it) != null }) return true
        return NumberWords.canRead(heard, token.digits)
    }

    private val NEGATIONS = setOf("not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without")

    private fun token(word: String): Token = when {
        isDigits(word) -> if (word.length <= MAX_NUMERAL_DIGITS) Token.Number(word) else Token.Mixed
        word.codePoints().anyMatch { Character.getType(it) == Character.DECIMAL_DIGIT_NUMBER.toInt() } -> Token.Mixed
        else -> Token.Word(word)
    }

    internal fun isDigits(word: String): Boolean = word.isNotEmpty() && word.all { it in '0'..'9' }

    /** Case-folded alphanumeric runs, with thousands separators removed so "2,026" is one numeral. */
    private fun words(text: String): List<String> {
        val lower = text.lowercase()
        val kept = StringBuilder()
        lower.forEachIndexed { index, char -> if (char != ',' || !isThousandsSeparator(lower, index)) kept.append(char) }
        val words = mutableListOf<String>()
        val current = StringBuilder()
        var index = 0
        while (index < kept.length) {
            val point = Character.codePointAt(kept, index)
            if (isAlphanumeric(point)) {
                current.appendCodePoint(point)
            } else if (current.isNotEmpty()) {
                words += current.toString()
                current.clear()
            }
            index += Character.charCount(point)
        }
        if (current.isNotEmpty()) words += current.toString()
        return words
    }

    private fun isThousandsSeparator(text: String, index: Int): Boolean {
        fun digit(offset: Int) = offset in text.indices && text[offset] in '0'..'9'
        return digit(index - 1) && (1..3).all { digit(index + it) } && !digit(index + 4)
    }

    private const val PUNCTUATION = ".,;:!?'\"’‘“”()[]{}-–—…"

    /** Symbols read aloud as words; a hyphen counts only as a minus sign directly before a digit. */
    private fun symbolCount(text: String): Int {
        val points = text.codePoints().toArray()
        return points.indices.count { index ->
            val point = points[index]
            if (point == '-'.code) {
                val startsWord = index == 0 || Character.isWhitespace(points[index - 1])
                startsWord && index + 1 < points.size && isNumber(points[index + 1])
            } else {
                !Character.isLetter(point) && !isNumber(point) && !Character.isWhitespace(point) && !isMark(point) &&
                    (point > Char.MAX_VALUE.code || point.toChar() !in PUNCTUATION)
            }
        }
    }

    private fun isNumber(point: Int) = when (Character.getType(point).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    /** Swift reads a combining mark as part of its letter, never as a symbol. */
    private fun isMark(point: Int) = when (Character.getType(point).toByte()) {
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK -> true
        else -> false
    }

    /** Foundation's `alphanumerics` covers letters, marks and numbers. */
    private fun isAlphanumeric(point: Int): Boolean = when (Character.getType(point).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER,
        -> true
        else -> false
    }
}

/** SpeakCore's `NumberWords`: enough English to check that a reading of a numeral reproduces its digits. */
internal object NumberWords {
    private val SMALL: Map<String, Long> = buildMap {
        val cardinals = listOf(
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        )
        val ordinals = listOf(
            "zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
            "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
            "nineteenth",
        )
        val tens = listOf("twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
        val tenths = listOf(
            "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        )
        put("oh", 0L)
        put("o", 0L)
        put("nought", 0L)
        cardinals.forEachIndexed { value, word -> put(word, value.toLong()) }
        ordinals.forEachIndexed { value, word -> put(word, value.toLong()) }
        tens.forEachIndexed { index, word -> put(word, (index + 2) * 10L) }
        tenths.forEachIndexed { index, word -> put(word, (index + 2) * 10L) }
    }

    private val SCALES = mapOf(
        "hundred" to 100L, "hundredth" to 100L, "thousand" to 1_000L, "thousandth" to 1_000L,
        "million" to 1_000_000L, "millionth" to 1_000_000L, "billion" to 1_000_000_000L, "billionth" to 1_000_000_000L,
    )

    /** Words between numbers that carry no digits ("three point five"). */
    private val SEPARATORS = setOf("and", "point", "dot", "comma", "colon", "dash", "hyphen")
    private val ZERO_WORDS = setOf("oh", "o", "nought")
    private const val LIMIT = 1_000_000_000_000_000L
    private const val MAX_DIGITS = 15

    fun value(word: String): Long? = SMALL[word] ?: SCALES[word]

    /** Whether [words] split into numbers whose digits, in order, are exactly [digits]; separators may sit between. */
    fun canRead(words: List<String>, digits: String): Boolean {
        val reachable = mutableSetOf(0 to 0)
        val frontier = ArrayDeque(listOf(0 to 0))
        while (frontier.isNotEmpty()) {
            val (word, digit) = frontier.removeLast()
            if (word == words.size) {
                if (digit == digits.length) return true
                continue
            }
            val next = mutableListOf<Pair<Int, Int>>()
            if (words[word] in SEPARATORS) next += word + 1 to digit
            for (end in word + 1..words.size) {
                for (reading in readings(words.subList(word, end))) {
                    val reachEnd = digit + reading.length
                    if (reachEnd <= digits.length && digits.regionMatches(digit, reading, 0, reading.length)) {
                        next += end to reachEnd
                    }
                }
            }
            next.filter(reachable::add).forEach(frontier::addLast)
        }
        return false
    }

    private fun readings(words: List<String>): List<String> {
        if (words.size == 1 && RealtimeReading.isDigits(words[0])) return listOf(words[0])
        if (words.size == 1 && (words[0] in ZERO_WORDS || words[0] == "zero")) return listOf("0")
        return listOfNotNull(cardinal(words)?.toString())
    }

    /** "two thousand and twenty six" is 2026 and "a hundred" is 100. */
    private fun cardinal(words: List<String>): Long? {
        var total = 0L
        var current = 0L
        var sawValue = false
        words.forEachIndexed { index, word ->
            val isLast = index == words.size - 1
            if (word == "and") {
                if (!sawValue || isLast) return null
                return@forEachIndexed
            }
            val small = SMALL[word]
            val scale = SCALES[word]
            when {
                word == "a" -> {
                    if (isLast || SCALES[words[index + 1]] == null) return null
                    current += 1
                }
                RealtimeReading.isDigits(word) && word.length <= MAX_DIGITS -> current += word.toLong()
                small != null && word !in ZERO_WORDS -> current += small
                scale == 100L -> current = maxOf(current, 1L) * 100
                scale != null -> {
                    total += maxOf(current, 1L) * scale
                    current = 0
                }
                else -> return null
            }
            sawValue = true
            if (total + current >= LIMIT) return null
        }
        return if (sawValue) total + current else null
    }
}

/**
 * Reads with an OpenAI Realtime voice. The next chunk is spoken while the current one plays, and
 * a chunk that fails stops the reading with its reason; it never falls back to another voice.
 */
class RealtimeReadAloudEngine(
    private val spec: RealtimeSpeechSpec,
    private val voice: RealtimeVoice,
    private val credential: String,
    private val synthesizer: RealtimeSpeechSynthesizer,
    private val output: PcmOutput,
) : ReadAloudEngine {
    override suspend fun play(text: String, language: String?, onAudible: () -> Unit) {
        val chunks = speechChunks(text.trim(), spec.chunkCharacters)
        if (chunks.isEmpty()) return
        try {
            coroutineScope {
                val audio = Channel<PcmAudio>(capacity = 1)
                launch(Dispatchers.IO) {
                    val session = synthesizer.open(voice, credential)
                    try {
                        chunks.forEach { audio.send(session.speak(it)) }
                    } finally {
                        session.close()
                    }
                    audio.close()
                }
                var audible = false
                for (piece in audio) {
                    if (!audible) {
                        audible = true
                        onAudible()
                    }
                    output.play(piece)
                }
                output.drain()
            }
        } finally {
            output.stop()
        }
    }

    override fun pause() = output.pause()

    override fun resume() = output.resume()
}
