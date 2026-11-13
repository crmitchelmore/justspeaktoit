package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONException
import org.json.JSONObject

/**
 * Deepgram streaming, mirroring SpeakCore's `DeepgramLiveClient`. Nova models use `v1/listen` with interim
 * results: finals append and each interim replaces the last. Flux models use `v2/listen`, where `Update`
 * revises the open turn and `EndOfTurn` finalises it. A finish sends `CloseStream`; `Metadata` (or a
 * short grace, longer for Flux, which closes the socket itself) ends it.
 */
class DeepgramLiveSession(
    private val model: CloudModel,
    private val language: String?,
    private val keyterms: List<String>,
    scheduler: LiveScheduler,
    sockets: LiveSocketFactory,
    listener: LiveTranscriptListener,
) : LiveSession(scheduler, sockets, listener, checkNotNull(model.live).sampleRate) {
    private val flux = isFlux(model.apiName)
    private val finals = mutableListOf<String>()
    private var interim = ""

    override val finishDeadlineMs: Long = 5_000

    override fun request(apiKey: String): LiveRequest =
        LiveRequest(url(model, language, keyterms), mapOf("Authorization" to "Token $apiKey"))

    override fun encode(pcm: ByteArray): List<ByteArray> = listOf(pcm)

    override fun sendAudio(socket: LiveSocket, frame: ByteArray): Boolean = socket.send(frame)

    override fun onSocketOpen(socket: LiveSocket) = markReady()

    override fun onMessage(text: String) {
        val message = try {
            JSONObject(text)
        } catch (_: JSONException) {
            return
        }
        if (message.optString("type") == "Metadata") {
            if (endSignalSent) complete()
            return
        }
        val event = transcriptEvent(message) ?: return
        if (event.second) {
            finals += event.first.trim()
            interim = ""
        } else {
            interim = event.first
        }
        publish()
    }

    override fun startFinish(socket: LiveSocket) {
        if (!socket.send(CLOSE_STREAM)) {
            fail(DictationFailure.Network)
            return
        }
        endSignalSent = true
        after(if (flux) FLUX_CLOSE_GRACE_MS else CLOSE_GRACE_MS) { completeIfDrained() }
    }

    override fun transcript(): String = (finals + interim.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    /** An open Flux turn is folded in at close; a Nova interim was superseded by the finals CloseStream flushed. */
    override fun finalTranscript(): String =
        if (flux) transcript() else finals.filter { it.isNotEmpty() }.joinToString(" ")

    private fun transcriptEvent(message: JSONObject): Pair<String, Boolean>? {
        if (flux) {
            val transcript = message.optString("transcript")
            return if (transcript.isEmpty()) null else transcript to (message.optString("event") == "EndOfTurn")
        }
        val transcript = message.optJSONObject("channel")
            ?.optJSONArray("alternatives")
            ?.optJSONObject(0)
            ?.optString("transcript")
            .orEmpty()
        return if (transcript.isEmpty()) null else transcript to message.optBoolean("is_final")
    }

    companion object {
        const val CLOSE_STREAM = """{"type":"CloseStream"}"""
        private const val CLOSE_GRACE_MS = 1_000L
        private const val FLUX_CLOSE_GRACE_MS = 3_000L

        fun isFlux(apiName: String): Boolean = apiName.startsWith("flux-")

        fun url(model: CloudModel, language: String?, keyterms: List<String>): String {
            val route = checkNotNull(model.live)
            val flux = isFlux(model.apiName)
            val items = mutableListOf(
                "model" to model.apiName,
                "encoding" to "linear16",
                "sample_rate" to route.sampleRate.toString(),
            )
            if (!flux) {
                items += listOf(
                    "punctuate" to "true", "smart_format" to "true", "numerals" to "true",
                    "interim_results" to "true", "channels" to "1", "endpointing" to "300", "vad_events" to "true",
                )
            }
            if (route.languageField.isNotEmpty() && !language.isNullOrEmpty()) items += route.languageField to language
            if (route.vocabularyField.isNotEmpty()) {
                items += LiveVocabulary.deepgramKeyterms(keyterms).map { route.vocabularyField to it }
            }
            val version = if (flux) "v2" else "v1"
            return "${model.provider.baseUrl}/$version/listen?${queryString(items)}"
        }
    }
}
