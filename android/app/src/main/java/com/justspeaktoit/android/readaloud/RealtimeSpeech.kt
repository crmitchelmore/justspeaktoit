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
import java.text.Normalizer
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
                        // Only an explicit "completed" is a finished reading.
                        val status = response?.optString("status")?.takeIf { it.isNotEmpty() } ?: NO_STATUS
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
        const val NO_STATUS = "no status"
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
 * a token mixing letters and digits is that bounded slot; a numeral's minus sign must be read as one word
 * carrying no number ("minus"); a decimal point between digits may be read as one such word ("point") or
 * left out, never inside an integer; and unmatched spoken words are allowed only for symbols read aloud,
 * `perSymbol` each.
 */
object RealtimeReading {
    /** Longer digit runs are not parsed as numbers; they become bounded slots. */
    private const val MAX_NUMERAL_DIGITS = 15

    private sealed interface Token {
        data class Word(val text: String) : Token
        data class Number(val digits: String) : Token
        data object Mixed : Token
        data object Minus : Token
        data object Point : Token
    }

    /** What [words] emits for a minus sign and a decimal point; no alphanumeric run can produce either. */
    private const val MINUS_WORD = "-"
    private const val POINT_WORD = "."

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
        val next = heard.getOrNull(start)
        when (token) {
            is Token.Word -> return if (next == token.text) listOf(start + 1) else emptyList()
            Token.Minus -> return if (next != null && isSign(next)) listOf(start + 1) else emptyList()
            Token.Point -> return if (next != null && isPoint(next)) listOf(start, start + 1) else listOf(start)
            is Token.Number, Token.Mixed -> Unit
        }
        val longest = minOf(heard.size, start + perNumeral)
        return (start + 1..longest).filter { accepts(token, heard.subList(start, it)) }
    }

    private fun accepts(token: Token, heard: List<String>): Boolean {
        if (heard.any { it in NEGATIONS }) return false
        if (token !is Token.Number) return true
        if (heard.none { isDigits(it) || NumberWords.value(it) != null }) return true
        return NumberWords.canRead(heard, token.digits)
    }

    /** A spoken sign or decimal point: a word with no digits, number or negation in it. */
    private fun carriesNoNumber(word: String) = !isDigits(word) && NumberWords.value(word) == null && word !in NEGATIONS

    /** Words that change the arithmetic when read in the other slot, so the language-neutral slots refuse them. */
    private fun isSign(word: String) = carriesNoNumber(word) && word !in POINT_WORDS

    private fun isPoint(word: String) = carriesNoNumber(word) && word !in SIGN_WORDS

    private val SIGN_WORDS = setOf("minus", "plus", "negative", "positive", "times", "over", "divided")
    private val POINT_WORDS = setOf("point", "dot")

    private val NEGATIONS = setOf("not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "without")

    private fun token(word: String): Token = when {
        word == MINUS_WORD -> Token.Minus
        word == POINT_WORD -> Token.Point
        isDigits(word) -> if (word.length <= MAX_NUMERAL_DIGITS) Token.Number(word) else Token.Mixed
        word.codePoints().anyMatch { Character.getType(it) == Character.DECIMAL_DIGIT_NUMBER.toInt() } -> Token.Mixed
        else -> Token.Word(word)
    }

    internal fun isDigits(word: String): Boolean = word.isNotEmpty() && word.all { it in '0'..'9' }

    /**
     * Case-folded NFC alphanumeric runs, so a composed and a decomposed "café" match, with thousands separators
     * removed so "2,026" is one numeral, and [MINUS_WORD] and [POINT_WORD] for a numeral's sign and decimal point.
     */
    private fun words(text: String): List<String> {
        val points = Normalizer.normalize(text, Normalizer.Form.NFC).lowercase().codePoints().toArray()
        val words = mutableListOf<String>()
        val current = StringBuilder()
        fun flush() {
            if (current.isNotEmpty()) words += current.toString()
            current.clear()
        }
        points.forEachIndexed { index, point ->
            when {
                point == ','.code && isThousandsSeparator(points, index) -> Unit
                isMinusSign(points, index) || isDecimalPoint(points, index) -> {
                    flush()
                    words += if (point == '.'.code) POINT_WORD else MINUS_WORD
                }
                isAlphanumeric(point) -> current.appendCodePoint(point)
                else -> flush()
            }
        }
        flush()
        return words
    }

    private fun isDigit(points: IntArray, index: Int) = index in points.indices && points[index] in '0'.code..'9'.code

    private fun isThousandsSeparator(points: IntArray, index: Int): Boolean =
        isDigit(points, index - 1) && (1..3).all { isDigit(points, index + it) } && !isDigit(points, index + 4)

    /** A hyphen or minus sign starting a word, directly before a digit. */
    private fun isMinusSign(points: IntArray, index: Int): Boolean {
        if (points[index] != '-'.code && points[index] != MINUS_SIGN) return false
        return (index == 0 || Character.isWhitespace(points[index - 1])) && isDigit(points, index + 1)
    }

    private fun isDecimalPoint(points: IntArray, index: Int): Boolean =
        points[index] == '.'.code && isDigit(points, index - 1) && isDigit(points, index + 1)

    private const val MINUS_SIGN = 0x2212

    private const val PUNCTUATION = ".,;:!?'\"’‘“”()[]{}-–—…"

    /** Symbols read aloud as words; a numeral's minus sign is not one, as it is a slot that must be read. */
    private fun symbolCount(text: String): Int {
        val points = text.codePoints().toArray()
        return points.indices.count { index ->
            val point = points[index]
            !isMinusSign(points, index) &&
                !Character.isLetter(point) && !isNumber(point) && !Character.isWhitespace(point) && !isMark(point) &&
                (point > Char.MAX_VALUE.code || point.toChar() !in PUNCTUATION)
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

    /** Words between numbers that carry no digits ("ten colon thirty"); never a decimal point inside an integer. */
    private val SEPARATORS = setOf("and", "comma", "colon", "dash", "hyphen")
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
                scale != null -> {
                    // Checked before multiplying, which would otherwise wrap.
                    val base = maxOf(current, 1L)
                    if (base > (LIMIT - 1 - total) / scale) return null
                    if (scale == 100L) {
                        current = base * 100
                    } else {
                        total += base * scale
                        current = 0
                    }
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
