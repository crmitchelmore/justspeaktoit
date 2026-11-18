package com.justspeaktoit.android.readaloud

import com.justspeaktoit.android.cloud.AzureSpeechCredential
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64

/**
 * One HTTP exchange, without a client library, so tests can answer with fakes. [maxResponseBytes] caps the body
 * the transport reads; null keeps its speech-response limit.
 */
data class SpeechHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray,
    val maxResponseBytes: Long? = null,
)

data class SpeechHttpResponse(val status: Int, val body: ByteArray)

/** A response body longer than a [SpeechHttp] reads; reported as invalid audio, not as no network. */
class SpeechResponseTooLarge(limit: Long) : IOException("response body exceeds $limit bytes")

interface SpeechHttp {
    /** Throws IOException when the provider cannot be reached; cancelling the caller cancels the call. */
    suspend fun send(request: SpeechHttpRequest): SpeechHttpResponse
}

/** 16-bit little-endian PCM. */
class PcmAudio(val sampleRate: Int, val channels: Int, val data: ByteArray)

/** Why read aloud stopped, shown to the user; never a reason to switch to another voice. */
sealed interface ReadAloudFailure {
    data class MissingKey(val provider: String) : ReadAloudFailure
    data class KeyUnreadable(val provider: String) : ReadAloudFailure
    data class KeyRejected(val provider: String) : ReadAloudFailure
    data class OutOfCredit(val provider: String) : ReadAloudFailure
    data class RateLimited(val provider: String) : ReadAloudFailure
    data class ServiceError(val provider: String, val status: Int) : ReadAloudFailure
    data class Unreachable(val provider: String) : ReadAloudFailure
    data class InvalidAudio(val provider: String) : ReadAloudFailure
    data class TooLong(val provider: String) : ReadAloudFailure
    /** The account's voice list could not be read, so no account voice is offered. */
    data class InvalidVoiceList(val provider: String) : ReadAloudFailure
    /** The model answered or summarised rather than reading the text verbatim. */
    data class NotAReading(val provider: String) : ReadAloudFailure
    /** The provider explained why it stopped. */
    data class ServiceMessage(val provider: String, val message: String) : ReadAloudFailure
    data class TimedOut(val provider: String) : ReadAloudFailure
    data object VoiceUnavailable : ReadAloudFailure
    data object SystemUnavailable : ReadAloudFailure
    data object AudioBusy : ReadAloudFailure
    data object PlaybackFailed : ReadAloudFailure
}

class ReadAloudException(val failure: ReadAloudFailure) : Exception(failure.toString())

/**
 * Speaks text with a [CloudVoice] by filling in its exported request template, one request per
 * segment, as the desktop host's `DesktopSpeechSynthesis` does with the same shared request builders.
 */
class CloudSpeechSynthesizer(private val http: SpeechHttp) {
    /** One part of a reading: the text, and whether it goes through the voice's dialogue request. */
    data class Segment(val text: String, val dialogue: Boolean)

    /**
     * The requests [text] needs. A dialogue-only model speaks text that fits its dialogue limit in one
     * request; longer text goes to its fallback model, as on the desktop.
     */
    fun plan(voice: CloudVoice, text: String): List<Segment> {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return emptyList()
        val dialogue = voice.dialogue
        if (dialogue != null && trimmed.length <= dialogue.maxCharacters) return listOf(Segment(trimmed, dialogue = true))
        val segments = speechChunks(trimmed, voice.maxCharacters).map { Segment(it, dialogue = false) }
        if (voice.maxSegments != null && segments.size > voice.maxSegments) {
            throw ReadAloudException(ReadAloudFailure.TooLong(voice.providerName))
        }
        return segments
    }

    /** The audio of one segment; [credential] is the saved API key, [language] a base language code. */
    suspend fun synthesize(voice: CloudVoice, segment: Segment, credential: String, language: String): PcmAudio {
        val values = values(voice, credential, language)
        val dialogue = voice.dialogue
        if (segment.dialogue && dialogue != null) {
            val response = exchange(voice, dialogue.request, segment.text, values)
            if (response.status in 200..299) return audio(voice, response.body)
            // The dialogue endpoint refused the request; the same text goes to the fallback model.
            if (response.status !in dialogue.fallbackStatuses) throw failure(voice, response.status)
        }
        // Gemini sometimes answers with text instead of audio, or a server fault; like SpeakCore's
        // `GeminiTTSAPI`, either is retried once. Other providers' answers are final.
        val attempts = if (voice.response == VoiceResponse.GeminiInteraction) 1 + GEMINI_RETRIES else 1
        var outcome: ReadAloudException? = null
        repeat(attempts) {
            val response = exchange(voice, voice.request, segment.text, values)
            if (response.status !in 200..299) {
                outcome = failure(voice, response.status)
                if (response.status < SERVER_FAULT) throw checkNotNull(outcome)
            } else {
                val audio = decode(voice, response.body)
                if (audio != null) return audio
                outcome = ReadAloudException(ReadAloudFailure.InvalidAudio(voice.providerName))
            }
        }
        throw checkNotNull(outcome)
    }

    private fun values(voice: CloudVoice, credential: String, language: String): Map<String, String> {
        val secret = credential.trim()
        if (secret.isEmpty()) throw ReadAloudException(ReadAloudFailure.MissingKey(voice.providerName))
        val usesRegion = voice.request.url.contains(REGION) || voice.request.headers.values.any { REGION in it }
        val voiceValue = voice.voiceValue?.let { mapOf(VOICE to it) }.orEmpty()
        if (!usesRegion) return mapOf(KEY to secret, LANGUAGE to language) + voiceValue
        val parsed = AzureSpeechCredential.parse(secret)
            ?: throw ReadAloudException(ReadAloudFailure.KeyRejected(voice.providerName))
        return mapOf(KEY to parsed.apiKey, REGION to parsed.region, LANGUAGE to language) + voiceValue
    }

    private suspend fun exchange(
        voice: CloudVoice,
        template: VoiceRequestTemplate,
        text: String,
        values: Map<String, String>,
    ): SpeechHttpResponse {
        val request = request(template, values + (TEXT to text))
        return try {
            http.send(request)
        } catch (_: SpeechResponseTooLarge) {
            throw ReadAloudException(ReadAloudFailure.InvalidAudio(voice.providerName))
        } catch (_: IOException) {
            throw ReadAloudException(ReadAloudFailure.Unreachable(voice.providerName))
        }
    }

    private fun audio(voice: CloudVoice, body: ByteArray): PcmAudio =
        decode(voice, body) ?: throw ReadAloudException(ReadAloudFailure.InvalidAudio(voice.providerName))

    /** Whole frames only: a speaker accepts complete frames, so a partial one at the end is dropped. */
    private fun decode(voice: CloudVoice, body: ByteArray): PcmAudio? {
        val audio = when (voice.response) {
            VoiceResponse.Wav -> WavAudio.parse(body)
            VoiceResponse.GeminiInteraction -> geminiAudio(body, voice.sampleRate)
            VoiceResponse.Base64Wav -> base64Wav(body, voice.audioField ?: return null)
        } ?: return null
        return wholeFrames(audio).takeIf { it.data.isNotEmpty() }
    }

    private fun failure(voice: CloudVoice, status: Int): ReadAloudException {
        val provider = voice.providerName
        return ReadAloudException(
            when (status) {
                401, 403 -> ReadAloudFailure.KeyRejected(provider)
                402 -> ReadAloudFailure.OutOfCredit(provider)
                429 -> ReadAloudFailure.RateLimited(provider)
                else -> ReadAloudFailure.ServiceError(provider, status)
            },
        )
    }

    companion object {
        private const val TEXT = "text"
        private const val KEY = "key"
        private const val REGION = "region"
        private const val LANGUAGE = "language"
        private const val VOICE = "voice"
        private const val SERVER_FAULT = 500
        private const val GEMINI_RETRIES = 1
        private val PLACEHOLDER = Regex("""\{(text|key|region|language|voice)\}""")

        /** The request with every placeholder filled in one pass, so text can never become a key. */
        fun request(template: VoiceRequestTemplate, values: Map<String, String>): SpeechHttpRequest {
            val body = when {
                template.xmlBody != null -> fill(template.xmlBody, values.mapValues { (name, value) ->
                    if (name == TEXT) escapeXml(value) else value
                })
                template.jsonBody != null -> filled(template.jsonBody, values).toString()
                else -> ""
            }
            return SpeechHttpRequest(
                method = template.method,
                url = fill(template.url, values),
                headers = template.headers.mapValues { fill(it.value, values) },
                body = body.toByteArray(Charsets.UTF_8),
            )
        }

        private fun fill(text: String, values: Map<String, String>): String =
            PLACEHOLDER.replace(text) { match -> values[match.groupValues[1]] ?: match.value }

        private fun filled(value: Any?, values: Map<String, String>): Any? = when (value) {
            is String -> fill(value, values)
            is JSONObject -> JSONObject().also { copy ->
                value.keys().forEach { name -> copy.put(name, filled(value.get(name), values)) }
            }
            is JSONArray -> JSONArray().also { copy ->
                for (index in 0 until value.length()) copy.put(filled(value.get(index), values))
            }
            else -> value
        }

        /** SpeakCore's `VoiceSynthesisMarkup.escapeXML`. */
        fun escapeXml(text: String): String = buildString(text.length) {
            for (char in text) {
                when (char) {
                    '&' -> append("&amp;")
                    '<' -> append("&lt;")
                    '>' -> append("&gt;")
                    '"' -> append("&quot;")
                    '\'' -> append("&apos;")
                    else -> append(char)
                }
            }
        }

        /** The base64 L16 audio of a Gemini Interactions response, as `GeminiTTSAPI.audio(from:)` reads it. */
        fun geminiAudio(body: ByteArray, requestedSampleRate: Int): PcmAudio? = try {
            val steps = JSONObject(String(body, Charsets.UTF_8)).optJSONArray("steps") ?: JSONArray()
            val block = (0 until steps.length()).asSequence()
                .mapNotNull { steps.optJSONObject(it)?.optJSONArray("content") }
                .flatMap { content -> (0 until content.length()).asSequence().mapNotNull(content::optJSONObject) }
                .firstOrNull { it.optString("type") == "audio" }
            val encoded = block?.optString("data").orEmpty()
            val bytes = if (encoded.isEmpty()) null else Base64.getMimeDecoder().decode(encoded)
            if (block == null || bytes == null || bytes.isEmpty()) {
                null
            } else {
                val rate = block.optInt("sample_rate", requestedSampleRate)
                val channels = block.optInt("channels", 1)
                if (rate <= 0 || channels !in 1..2) null else PcmAudio(rate, channels, bytes.evenLength())
            }
        } catch (_: JSONException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }

        /** The WAV in [field] of a JSON body, base64-encoded, as SpeakCore's `MistralTTSAPI` reads `audio_data`. */
        fun base64Wav(body: ByteArray, field: String): PcmAudio? = try {
            val encoded = JSONObject(String(body, Charsets.UTF_8)).optString(field)
            if (encoded.isEmpty()) null else WavAudio.parse(Base64.getMimeDecoder().decode(encoded))
        } catch (_: JSONException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }

        private fun ByteArray.evenLength(): ByteArray = if (size % 2 == 0) this else copyOf(size - 1)

        /** [audio] cut to whole 16-bit frames of all its channels. */
        fun wholeFrames(audio: PcmAudio): PcmAudio {
            val frame = 2 * audio.channels
            val extra = audio.data.size % frame
            return if (extra == 0) audio else PcmAudio(audio.sampleRate, audio.channels, audio.data.copyOf(audio.data.size - extra))
        }
    }
}

/** Reads the 16-bit PCM of a WAV file, tolerating the unknown sizes a streamed response carries. */
object WavAudio {
    private const val PCM = 1
    private const val EXTENSIBLE = 0xFFFE
    private const val HEADER = 12
    private const val CHUNK_HEADER = 8

    /**
     * `data` sizes that mean "length unknown": 0 and 0x7FFF0000 as SpeakCore's `DeepgramSpeechWAV`
     * accepts, and 0xFFFFFFFF, which streaming encoders write when they cannot seek back.
     */
    private val STREAMED_SIZES = setOf(0L, 0x7FFF0000L, 0xFFFFFFFFL)

    fun parse(bytes: ByteArray): PcmAudio? {
        if (bytes.size < HEADER || String(bytes, 0, 4, Charsets.US_ASCII) != "RIFF" ||
            String(bytes, 8, 4, Charsets.US_ASCII) != "WAVE"
        ) {
            return null
        }
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = HEADER
        var sampleRate = 0
        var channels = 0
        while (offset + CHUNK_HEADER <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val declared = buffer.getInt(offset + 4).toLong() and 0xFFFFFFFFL
            val start = offset + CHUNK_HEADER
            val available = (bytes.size - start).toLong()
            when (id) {
                "fmt " -> {
                    if (declared < 16 || available < 16) return null
                    val format = buffer.getShort(start).toInt() and 0xFFFF
                    channels = buffer.getShort(start + 2).toInt()
                    sampleRate = buffer.getInt(start + 4)
                    val bits = buffer.getShort(start + 14).toInt()
                    if ((format != PCM && format != EXTENSIBLE) || bits != 16 || channels !in 1..2 || sampleRate <= 0) {
                        return null
                    }
                }
                "data" -> {
                    if (sampleRate == 0) return null
                    // A streamed WAV declares a sentinel and its data runs to the end; any other
                    // length is finite, and one the body does not reach is truncated audio.
                    val length = when {
                        declared in STREAMED_SIZES -> available
                        declared > available -> return null
                        else -> declared
                    }
                    val even = (length - length % 2).toInt()
                    return PcmAudio(sampleRate, channels, bytes.copyOfRange(start, start + even))
                }
            }
            if (declared > available) return null
            offset = start + declared.toInt() + (declared % 2).toInt()
        }
        return null
    }
}
