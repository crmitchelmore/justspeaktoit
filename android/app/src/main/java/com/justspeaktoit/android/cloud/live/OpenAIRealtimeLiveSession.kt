package com.justspeaktoit.android.cloud.live

import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Base64

/**
 * OpenAI Realtime transcription (GA), mirroring SpeakCore's `OpenAIRealtimeLiveClient`:
 * - `?intent=transcription` with no `OpenAI-Beta` header, and the shared `session.update` payload;
 * - audio waits for `session.updated` for a transcription session, then goes up as base64 24 kHz PCM;
 * - deltas append to their item and a completed event replaces it; items keep commit order;
 * - turn detection is off, so a stop commits once (padded to 100 ms, never empty) and waits for that
 *   item's completion or the catalogue's finalise budget, within an eight-second bound.
 */
class OpenAIRealtimeLiveSession(
    private val model: CloudModel,
    private val language: String?,
    private val prompt: String?,
    scheduler: LiveScheduler,
    sockets: LiveSocketFactory,
    listener: LiveTranscriptListener,
) : LiveSession(scheduler, sockets, listener, checkNotNull(model.live).sampleRate) {
    private val route = checkNotNull(model.live)
    private val resampler = Pcm16Resampler(RECORDER_SAMPLE_RATE, route.sampleRate)
    private val itemOrder = mutableListOf<String>()
    private val deltas = HashMap<String, String>()
    private val completed = HashMap<String, String>()
    private var audioBytesSinceCommit = 0
    private var commitSent = false
    private var finalItem: String? = null

    override fun request(apiKey: String): LiveRequest =
        LiveRequest("$ENDPOINT?intent=transcription", mapOf("Authorization" to "Bearer $apiKey"))

    override fun encode(pcm: ByteArray): List<ByteArray> = listOf(resampler.process(pcm))

    override fun sendAudio(socket: LiveSocket, frame: ByteArray): Boolean {
        audioBytesSinceCommit += frame.size
        return socket.send(appendJson(frame))
    }

    override fun onSocketOpen(socket: LiveSocket) {
        if (!socket.send(sessionUpdateJson(model, language, prompt))) fail(DictationFailure.Network)
    }

    override fun onMessage(text: String) {
        val message = try {
            JSONObject(text)
        } catch (_: JSONException) {
            return
        }
        val item = message.optString("item_id").ifEmpty { PENDING_ITEM }
        when (message.optString("type")) {
            "session.updated", "transcription_session.updated" -> {
                val type = message.optJSONObject("session")?.optString("type").orEmpty()
                if (type.isNotEmpty() && type != "transcription") fail(DictationFailure.Server) else markReady()
            }
            "input_audio_buffer.committed" -> {
                register(item)
                if (commitSent && finalItem == null) finalItem = item
            }
            "conversation.item.input_audio_transcription.delta" -> {
                val delta = message.optString("delta")
                if (delta.isEmpty()) return
                register(item)
                if (item !in completed) deltas[item] = deltas[item].orEmpty() + delta
                publish()
            }
            "conversation.item.input_audio_transcription.completed" -> {
                register(item)
                completed[item] = message.optString("transcript")
                deltas.remove(item)
                publish()
                if (commitSent && item == finalItem) complete()
            }
            "conversation.item.input_audio_transcription.failed" ->
                if (commitSent && item == finalItem) fail(DictationFailure.Server)
            "error" -> handleError(message.optJSONObject("error")?.optString("event_id"))
        }
    }

    override fun startFinish(socket: LiveSocket) {
        val shortfall = MINIMUM_COMMIT_BYTES - audioBytesSinceCommit
        if (shortfall > 0 && !sendAudio(socket, ByteArray(shortfall))) {
            fail(DictationFailure.Network)
            return
        }
        if (!socket.send(commitJson())) {
            fail(DictationFailure.Network)
            return
        }
        commitSent = true
        endSignalSent = true
        audioBytesSinceCommit = 0
        after(route.finalizeBudgetMs) { completeIfDrained() }
    }

    override fun transcript(): String = itemOrder
        .mapNotNull { (completed[it] ?: deltas[it])?.trim() }
        .filter { it.isNotEmpty() }
        .joinToString(" ")

    /** Errors are usually recoverable; only one about our session configuration or the final commit ends the run. */
    private fun handleError(eventId: String?) {
        when {
            eventId == SESSION_UPDATE_EVENT_ID -> fail(DictationFailure.Server)
            eventId == COMMIT_EVENT_ID -> fail(DictationFailure.Server)
            eventId.isNullOrEmpty() && commitSent -> fail(DictationFailure.Server)
        }
    }

    private fun register(item: String) {
        if (item !in itemOrder) itemOrder += item
    }

    private fun appendJson(pcm: ByteArray): String =
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"" + Base64.getEncoder().encodeToString(pcm) + "\"}"

    companion object {
        const val ENDPOINT = "wss://api.openai.com/v1/realtime"
        const val SESSION_UPDATE_EVENT_ID = "jsti_session_update"
        const val COMMIT_EVENT_ID = "jsti_final_commit"
        private const val PENDING_ITEM = "_pending"
        private const val RECORDER_SAMPLE_RATE = 16_000

        /** The server rejects commits under 100 ms of 24 kHz PCM16. */
        const val MINIMUM_COMMIT_BYTES = 24_000 * 2 / 10

        fun commitJson(): String = """{"type":"input_audio_buffer.commit","event_id":"$COMMIT_EVENT_ID"}"""

        /** SpeakCore's `OpenAITranscriptionModels.realtimeSessionUpdatePayload`, with an `event_id`. */
        fun sessionUpdateJson(model: CloudModel, language: String?, prompt: String?): String {
            val route = checkNotNull(model.live)
            val transcription = JSONObject().put("model", model.apiName)
            if (!language.isNullOrEmpty()) {
                when (route.languageField) {
                    "languages" -> transcription.put("languages", JSONArray().put(language))
                    "language" -> transcription.put("language", language)
                }
            }
            if (route.vocabularyField == "prompt" && !prompt.isNullOrBlank()) transcription.put("prompt", prompt)
            val input = JSONObject()
                .put("format", JSONObject().put("type", "audio/pcm").put("rate", route.sampleRate))
                .put("transcription", transcription)
                .put("noise_reduction", JSONObject().put("type", "near_field"))
                .put("turn_detection", JSONObject.NULL)
            return JSONObject()
                .put("type", "session.update")
                .put("event_id", SESSION_UPDATE_EVENT_ID)
                .put(
                    "session",
                    JSONObject().put("type", "transcription").put("audio", JSONObject().put("input", input)),
                )
                .toString()
        }
    }
}
