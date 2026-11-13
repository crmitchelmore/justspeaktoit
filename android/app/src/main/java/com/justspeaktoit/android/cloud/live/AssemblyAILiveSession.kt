package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.TreeMap

/**
 * AssemblyAI Universal-3.6 Pro streaming (v3), mirroring SpeakCore's `AssemblyAILiveClient`:
 * - the EU host first, then the global host once, only when the attempt fails before `Begin`
 *   (a `Begin` slower than eight seconds counts) and the run is not finishing;
 * - audio waits for `Begin` and goes up in 100 ms frames, the last tail padded to 50 ms;
 * - `Turn` partials replace their turn's text; a turn commits only when `end_of_turn` and
 *   `turn_is_formatted` are both set;
 * - a stop sends `ForceEndpoint`, waits up to the catalogue's finalise budget for the formatted turn,
 *   then sends `Terminate`; the whole finish is bounded by eight seconds.
 */
class AssemblyAILiveSession(
    private val model: CloudModel,
    private val keyterms: List<String>,
    scheduler: LiveScheduler,
    sockets: LiveSocketFactory,
    listener: LiveTranscriptListener,
) : LiveSession(scheduler, sockets, listener, checkNotNull(model.live).sampleRate) {
    private val route = checkNotNull(model.live)
    private val framer = PcmFramer(
        frameBytes = route.sampleRate * BYTES_PER_SAMPLE / FRAMES_PER_SECOND,
        minimumTailBytes = route.sampleRate * BYTES_PER_SAMPLE / MINIMUM_TAIL_DIVISOR,
    )
    private var hostIndex = 0
    private val finals = TreeMap<Int, String>()
    private val interims = TreeMap<Int, String>()
    private var forceEndpointSent = false

    /** The host the current attempt uses. */
    val host: String get() = HOSTS[hostIndex]

    override val readyDeadlineMs: Long = BEGIN_DEADLINE_MS
    override val finishDeadlineMs: Long = 8_000

    override fun request(apiKey: String): LiveRequest =
        LiveRequest(url(model, host, apiKey, keyterms), mapOf("Authorization" to apiKey))

    override fun encode(pcm: ByteArray): List<ByteArray> = framer.push(pcm)

    override fun encodeTail(): List<ByteArray> = framer.finish()

    override fun sendAudio(socket: LiveSocket, frame: ByteArray): Boolean = socket.send(frame)

    override fun retryBeforeReady(): Boolean {
        if (hostIndex != 0) return false
        hostIndex = 1
        return true
    }

    override fun onMessage(text: String) {
        val message = try {
            JSONObject(text)
        } catch (_: JSONException) {
            return
        }
        val type = message.optString("type").ifEmpty { if (message.has("turn_order")) "Turn" else "" }
        when (type) {
            "Begin" -> markReady()
            "Turn" -> if (ready) receiveTurn(message)
            "Termination" -> if (endSignalSent) complete() else fail(DictationFailure.Server)
            "Error" -> transportEnded(DictationFailure.Server)
        }
    }

    override fun startFinish(socket: LiveSocket) {
        if (!socket.send(FORCE_ENDPOINT)) {
            fail(DictationFailure.Network)
            return
        }
        forceEndpointSent = true
        if (route.finalizeBudgetMs <= 0) terminate() else after(route.finalizeBudgetMs) { terminate() }
    }

    override fun transcript(): String {
        val latestInterim = interims.lastEntry()?.value.orEmpty()
        return (finals.values + latestInterim).map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
    }

    private fun receiveTurn(message: JSONObject) {
        val order = message.optInt("turn_order")
        val text = message.optString("transcript")
        val endOfTurn = message.optBoolean("end_of_turn")
        if (text.isEmpty() && !endOfTurn) return
        val committed = endOfTurn && message.optBoolean("turn_is_formatted")
        if (committed) {
            finals[order] = text
            interims.remove(order)
        } else {
            interims[order] = text
        }
        publish()
        if (committed && forceEndpointSent) terminate()
    }

    private fun terminate() {
        if (endSignalSent || done) return
        if (currentSocket?.send(TERMINATE) != true) {
            fail(DictationFailure.Network)
            return
        }
        endSignalSent = true
        after(TERMINATION_GRACE_MS) { completeIfDrained() }
    }

    companion object {
        /** The EU host first, then the global one. */
        val HOSTS = listOf(CloudProvider.AssemblyAI.baseUrl.substringAfter("://"), "streaming.assemblyai.com")
        const val FORCE_ENDPOINT = """{"type":"ForceEndpoint"}"""
        const val TERMINATE = """{"type":"Terminate"}"""
        const val BEGIN_DEADLINE_MS = 8_000L
        private const val TERMINATION_GRACE_MS = 3_000L
        private const val MIN_TURN_SILENCE_MS = 560
        private const val FRAMES_PER_SECOND = 10

        /** AssemblyAI rejects frames shorter than 50 ms. */
        private const val MINIMUM_TAIL_DIVISOR = 20

        fun url(model: CloudModel, host: String, apiKey: String, keyterms: List<String>): String {
            val route = checkNotNull(model.live)
            val items = mutableListOf(
                "sample_rate" to route.sampleRate.toString(),
                "encoding" to "pcm_s16le",
                "speech_model" to model.apiName,
                "min_turn_silence" to MIN_TURN_SILENCE_MS.toString(),
                "token" to apiKey,
            )
            val terms = LiveVocabulary.assemblyAIKeyterms(keyterms)
            if (route.vocabularyField.isNotEmpty() && terms.isNotEmpty()) {
                items += route.vocabularyField to JSONArray(terms).toString()
            }
            return "wss://$host/v3/ws?${queryString(items)}"
        }
    }
}
