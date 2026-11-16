package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.BatchWire
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONException
import org.json.JSONObject
import java.util.Base64

/**
 * ElevenLabs Scribe realtime, mirroring SpeakCore's `ElevenLabsLiveClient`:
 * - one `/v1/speech-to-text/realtime` socket with `xi-api-key` auth and `commit_strategy=vad`; there is no
 *   fallback host, so a failure ends the session;
 * - audio waits for `session_started`, then goes up as base64 `input_audio_chunk` frames;
 * - a `partial_transcript` replaces the open segment and a committed segment replaces it; a timestamped
 *   twin of a segment already counted never adds it again;
 * - a stop drains the audio, sends one manual commit and reads the finals that follow for a bounded
 *   post-commit window, because VAD commits carry no id that marks the commit's own answer. Partials that
 *   arrive during that window are ignored, and the finish returns the committed segments.
 */
class ElevenLabsLiveSession(
    private val model: CloudModel,
    private val language: String?,
    private val keyterms: List<String>,
    scheduler: LiveScheduler,
    sockets: LiveSocketFactory,
    listener: LiveTranscriptListener,
) : LiveSession(scheduler, sockets, listener, checkNotNull(model.live).sampleRate) {
    private val route = checkNotNull(model.live)
    private val resampler = Pcm16Resampler(RECORDER_SAMPLE_RATE, route.sampleRate)
    private val finals = mutableListOf<String>()
    private var partial = ""
    private val twins = FinalTwinTracker()

    override val readyDeadlineMs: Long = READY_DEADLINE_MS

    override fun request(apiKey: String): LiveRequest =
        LiveRequest(url(model, language, keyterms), mapOf("xi-api-key" to apiKey.trim()))

    override fun encode(pcm: ByteArray): List<ByteArray> = listOf(resampler.process(pcm))

    override fun sendAudio(socket: LiveSocket, frame: ByteArray): Boolean =
        socket.send(audioChunkJson(frame, route.sampleRate))

    override fun onMessage(text: String) {
        val message = try {
            JSONObject(text)
        } catch (_: JSONException) {
            return
        }
        val type = message.optString("message_type")
        val transcript = message.optString("text")
        when (type) {
            "session_started" -> markReady()
            "partial_transcript" -> {
                if (!ready || finishRequested || transcript.isEmpty()) return
                partial = transcript
                publish()
            }
            "committed_transcript" -> committed(transcript, timestamped = false)
            "committed_transcript_with_timestamps" -> committed(transcript, timestamped = true)
            "auth_error" -> fail(DictationFailure.InvalidKey)
            in TERMINAL_ERRORS -> fail(failureFor(type))
            // `warning` and unknown frames are survivable.
        }
    }

    override fun startFinish(socket: LiveSocket) {
        if (!socket.send(COMMIT)) {
            fail(DictationFailure.Network)
            return
        }
        endSignalSent = true
        // The post-commit window starts once the audio and the commit have left the device.
        afterDrained { after(POST_COMMIT_WINDOW_MS) { completeIfDrained() } }
    }

    override fun transcript(): String = (finals + partial.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    /** Only committed segments: a partial the commit did not confirm in time is not returned as final text. */
    override fun finalTranscript(): String = finals.joinToString(" ")

    private fun committed(text: String, timestamped: Boolean) {
        if (!ready || text.isBlank() || twins.isTwin(timestamped)) return
        finals += text.trim()
        partial = ""
        publish()
    }

    /**
     * SpeakCore's `ElevenLabsFinalTwinTracker`: with timestamps on, ElevenLabs sends a segment in both forms,
     * and either may arrive alone. A form that arrives while the other form is outstanding is that segment again.
     */
    private class FinalTwinTracker {
        private var outstandingPlain = 0
        private var outstandingTimestamped = 0

        fun isTwin(timestamped: Boolean): Boolean {
            if (timestamped) {
                if (outstandingPlain > 0) {
                    outstandingPlain -= 1
                    return true
                }
                outstandingTimestamped += 1
            } else {
                if (outstandingTimestamped > 0) {
                    outstandingTimestamped -= 1
                    return true
                }
                outstandingPlain += 1
            }
            return false
        }
    }

    companion object {
        const val ENDPOINT = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        const val COMMIT = """{"message_type":"input_audio_chunk","audio_base_64":"","commit":true}"""
        const val READY_DEADLINE_MS = 10_000L

        /** `ElevenLabsLiveClient.finishBudget`: how long a stop reads finals once its commit has left. */
        const val POST_COMMIT_WINDOW_MS = 1_500L
        private const val RECORDER_SAMPLE_RATE = 16_000

        /** Realtime keyterms (`ElevenLabsLiveProtocol.boundedRealtimeKeyterms`): at most 50, of 20 characters. */
        private const val MAX_REALTIME_TERMS = 50
        private const val MAX_REALTIME_TERM_LENGTH = 20

        /** Error `message_type`s that end the session (`ElevenLabsRealtimeEvent.terminalErrorTypes`). */
        val TERMINAL_ERRORS = setOf(
            "error", "quota_exceeded", "rate_limited", "commit_throttled", "input_error",
            "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity",
            "transcriber_error", "session_time_limit_exceeded", "resource_exhausted",
            "queue_overflow", "unaccepted_terms",
        )

        private fun failureFor(type: String): DictationFailure = when (type) {
            "quota_exceeded", "rate_limited", "commit_throttled", "resource_exhausted" ->
                DictationFailure.TooManyRequests
            "input_error", "invalid_request", "chunk_size_exceeded", "unaccepted_terms" -> DictationFailure.Client
            else -> DictationFailure.Server
        }

        fun realtimeKeyterms(words: List<String>): List<String> = BatchWire.elevenLabsKeyterms(words)
            .filter { it.codePointCount(0, it.length) <= MAX_REALTIME_TERM_LENGTH }
            .take(MAX_REALTIME_TERMS)

        fun url(model: CloudModel, language: String?, keyterms: List<String>): String {
            val route = checkNotNull(model.live)
            val items = mutableListOf(
                "model_id" to model.apiName,
                "audio_format" to "pcm_${route.sampleRate}",
                "commit_strategy" to "vad",
            )
            if (route.languageField.isNotEmpty() && !language.isNullOrEmpty()) items += route.languageField to language
            if (route.vocabularyField.isNotEmpty()) {
                items += realtimeKeyterms(keyterms).map { route.vocabularyField to it }
            }
            return "$ENDPOINT?${queryString(items)}"
        }

        /** One PCM frame as an `input_audio_chunk`; base64 needs no JSON escaping. */
        fun audioChunkJson(pcm: ByteArray, sampleRate: Int): String =
            "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"" +
                Base64.getEncoder().encodeToString(pcm) + "\",\"sample_rate\":$sampleRate}"
    }
}
