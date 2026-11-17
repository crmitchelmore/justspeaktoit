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
            if (!RealtimeReading.isFaithful(chunk, transcript.toString(), spec.spokenWordsPerNumeral)) {
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

/** SpeakCore's `OpenAIRealtimeSpeech.isFaithfulReading`. */
object RealtimeReading {
    /**
     * Every input word must be spoken, in order; numerals are not required, but each allows
     * [perNumeral] extra spoken words, plus a small allowance for symbols read aloud.
     */
    fun isFaithful(expected: String, spoken: String, perNumeral: Int): Boolean {
        val input = words(expected)
        val rhs = words(spoken)
        val lhs = input.filterNot { word -> word.any(Character::isDigit) }
        val numerals = input.size - lhs.size
        val matched = commonSubsequence(lhs, rhs)
        val allowedExtra = numerals * perNumeral + maxOf(2, lhs.size / 10)
        return matched == lhs.size && rhs.size - matched <= allowedExtra
    }

    private fun commonSubsequence(lhs: List<String>, rhs: List<String>): Int {
        var previous = IntArray(rhs.size + 1)
        for (word in lhs) {
            val current = IntArray(rhs.size + 1)
            rhs.forEachIndexed { index, other ->
                current[index + 1] = if (word == other) previous[index] + 1 else maxOf(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[rhs.size]
    }

    /** Foundation's `alphanumerics` covers letters, marks and numbers. */
    private fun words(text: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        var index = 0
        val lower = text.lowercase()
        while (index < lower.length) {
            val point = lower.codePointAt(index)
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

    private fun isAlphanumeric(point: Int): Boolean = when (Character.getType(point).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER,
        -> true
        else -> false
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
