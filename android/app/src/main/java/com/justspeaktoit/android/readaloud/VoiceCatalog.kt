package com.justspeaktoit.android.readaloud

import org.json.JSONArray
import org.json.JSONObject

/** A request a voice sends, with `{text}`, `{key}`, `{region}` and `{language}` still to fill in. */
data class VoiceRequestTemplate(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    /** A JSON body; Android substitutes placeholders inside its string values. */
    val jsonBody: JSONObject?,
    /** An SSML body; the text replacing `{text}` is XML-escaped. */
    val xmlBody: String?,
)

/** ElevenLabs dialogue-only models: the dialogue request for text that fits, and when to fall back. */
data class DialogueTemplate(
    val maxCharacters: Int,
    val request: VoiceRequestTemplate,
    val fallbackStatuses: Set<Int>,
)

/** How a voice's response body carries its audio. */
enum class VoiceResponse { Wav, GeminiInteraction }

/** One cloud voice of `assets/voice_catalog.json`, which SpeakCore's `VoiceCatalogAndroidExport` writes. */
data class CloudVoice(
    /** `modelID|id`, unique across the catalogue and what Settings saves. */
    val key: String,
    val id: String,
    val name: String,
    val label: String,
    val provider: String,
    val providerName: String,
    val modelId: String,
    /** The `SecretStore` name of the API key, the one cloud transcription already uses. */
    val credentialId: String,
    val sampleRate: Int,
    val maxCharacters: Int,
    val maxSegments: Int?,
    val response: VoiceResponse,
    val request: VoiceRequestTemplate,
    val dialogue: DialogueTemplate?,
)

/** The voice catalogue and the shared pronunciation defaults, parsed from the exported asset. */
class VoiceCatalog(val voices: List<CloudVoice>, val pronunciationDefaults: List<PronunciationEntry>) {
    private val byKey = voices.associateBy { it.key }

    fun voice(key: String): CloudVoice? = byKey[key]

    /** Providers in catalogue order, each with its voices. */
    val providers: List<Pair<String, List<CloudVoice>>>
        get() = voices.groupBy { it.providerName }.toList()

    companion object {
        const val ASSET = "voice_catalog.json"
        private const val VERSION = 1

        fun parse(json: String): VoiceCatalog {
            val root = JSONObject(json)
            check(root.getInt("version") == VERSION) { "$ASSET version is not understood" }
            val voices = root.getJSONArray("voices").objects().map(::voice)
            val defaults = root.getJSONArray("pronunciationDefaults").objects().map { item ->
                val word = item.getString("word")
                PronunciationEntry(
                    id = PronunciationEntry.defaultId(word),
                    word = word,
                    pronunciation = item.getString("pronunciation"),
                    replacement = item.optStringOrNull("replacement"),
                    category = item.optStringOrNull("category"),
                    isRegex = item.getBoolean("isRegex"),
                    caseSensitive = item.getBoolean("caseSensitive"),
                )
            }
            return VoiceCatalog(voices, defaults)
        }

        private fun voice(item: JSONObject) = CloudVoice(
            key = item.getString("key"),
            id = item.getString("id"),
            name = item.getString("name"),
            label = item.getString("label"),
            provider = item.getString("provider"),
            providerName = item.getString("providerName"),
            modelId = item.getString("modelID"),
            credentialId = item.getString("credentialID"),
            sampleRate = item.getInt("sampleRate"),
            maxCharacters = item.getInt("maxCharacters"),
            maxSegments = if (item.has("maxSegments")) item.getInt("maxSegments") else null,
            response = when (val response = item.getString("response")) {
                "wav" -> VoiceResponse.Wav
                "geminiInteraction" -> VoiceResponse.GeminiInteraction
                else -> error("Unknown voice response $response")
            },
            request = template(item.getJSONObject("request")),
            dialogue = item.optJSONObject("dialogue")?.let { dialogue ->
                DialogueTemplate(
                    maxCharacters = dialogue.getInt("maxCharacters"),
                    request = template(dialogue.getJSONObject("request")),
                    fallbackStatuses = dialogue.getJSONArray("fallbackStatuses").let { array ->
                        (0 until array.length()).map(array::getInt).toSet()
                    },
                )
            },
        )

        private fun template(item: JSONObject): VoiceRequestTemplate {
            val headers = item.getJSONObject("headers")
            return VoiceRequestTemplate(
                method = item.getString("method"),
                url = item.getString("url"),
                headers = headers.keys().asSequence().associateWith(headers::getString),
                jsonBody = item.optJSONObject("jsonBody"),
                xmlBody = item.optStringOrNull("xmlBody"),
            )
        }

        private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map(::getJSONObject)

        private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key)) null else getString(key)
    }
}
