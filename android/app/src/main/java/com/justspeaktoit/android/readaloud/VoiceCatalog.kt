package com.justspeaktoit.android.readaloud

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** A request a voice sends, with `{text}`, `{key}`, `{region}`, `{language}` and `{voice}` still to fill in. */
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

/** How a voice's response body carries its audio: a WAV file, Gemini's L16 steps, or base64 WAV in a JSON field. */
enum class VoiceResponse { Wav, GeminiInteraction, Base64Wav }

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
    /** An account voice's API identifier, sent as `{voice}`. */
    val voiceValue: String? = null,
    /** The JSON field of a [VoiceResponse.Base64Wav] response that holds the audio. */
    val audioField: String? = null,
)

/** How an account's voices are listed: a GET with `{key}`, and the query item later pages add. */
data class AccountListRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    /** `offset` (a multiple of [pageSize]), `cursor` (the previous page's `next_page_cursor`) or null. */
    val pageParameter: String?,
    val pageSize: Int?,
    val maxPages: Int,
    val maxResponseBytes: Int,
    val timeoutSeconds: Int,
)

/** A provider whose voices are discovered from the user's account with the saved key. */
data class AccountVoiceProvider(
    val provider: String,
    val providerName: String,
    /** The listing response shape: `mistral`, `xai` or `soniox`. */
    val listing: String,
    val modelId: String,
    val credentialId: String,
    /** Templates over `{voice}`, a listed voice's API identifier, and `{name}`, its display name. */
    val keyTemplate: String,
    val idTemplate: String,
    val labelTemplate: String,
    val lowercaseVoiceId: Boolean,
    /** Documented preset voices, which the fixed catalogue already offers. */
    val fixedVoiceIds: List<String>,
    /** Soniox: a clone speaks only once its status for this model is `ready`. */
    val readyModel: String?,
    val maxVoices: Int,
    val list: AccountListRequest,
    val sampleRate: Int,
    val maxCharacters: Int,
    val maxSegments: Int?,
    val response: VoiceResponse,
    val audioField: String?,
    val request: VoiceRequestTemplate,
) {
    /** The voice that speaks with the account voice [apiId], shown as [name]. */
    fun voice(apiId: String, name: String): CloudVoice {
        val values = mapOf(VOICE to apiId, NAME to name)
        return CloudVoice(
            key = fill(keyTemplate, values),
            id = fill(idTemplate, values),
            name = name,
            label = fill(labelTemplate, values),
            provider = provider,
            providerName = providerName,
            modelId = modelId,
            credentialId = credentialId,
            sampleRate = sampleRate,
            maxCharacters = maxCharacters,
            maxSegments = maxSegments,
            response = response,
            request = request,
            dialogue = null,
            voiceValue = if (lowercaseVoiceId) apiId.lowercase(Locale.ROOT) else apiId,
            audioField = audioField,
        )
    }

    /** The API identifier a saved [key] names, when it is one of this provider's account voices. */
    fun apiVoiceId(key: String): String? {
        val at = keyTemplate.indexOf(VOICE_PLACEHOLDER)
        if (at < 0) return null
        val prefix = keyTemplate.substring(0, at)
        val suffix = keyTemplate.substring(at + VOICE_PLACEHOLDER.length)
        if (!key.startsWith(prefix) || !key.endsWith(suffix) || key.length <= prefix.length + suffix.length) return null
        return key.substring(prefix.length, key.length - suffix.length)
    }

    private companion object {
        const val VOICE = "voice"
        const val NAME = "name"
        const val VOICE_PLACEHOLDER = "{voice}"
        val PLACEHOLDER = Regex("""\{(voice|name)\}""")

        fun fill(text: String, values: Map<String, String>): String =
            PLACEHOLDER.replace(text) { match -> values[match.groupValues[1]] ?: match.value }
    }
}

/** One OpenAI Realtime voice; [voice] is the identifier the session sends as `{voice}`. */
data class RealtimeVoice(val key: String, val id: String, val name: String, val label: String, val voice: String)

/** The OpenAI Realtime speech session, exported from SpeakCore's `OpenAIRealtimeSpeech`. */
data class RealtimeSpeechSpec(
    val provider: String,
    val providerName: String,
    val displayName: String,
    val modelId: String,
    val credentialId: String,
    val url: String,
    val headers: Map<String, String>,
    val sessionUpdate: JSONObject,
    val responseCreate: JSONObject,
    val sampleRate: Int,
    val chunkCharacters: Int,
    val spokenWordsPerNumeral: Int,
    val responseTimeoutSeconds: Int,
    val voices: List<RealtimeVoice>,
) {
    private val byKey = voices.associateBy { it.key }

    fun voice(key: String): RealtimeVoice? = byKey[key]
}

/** The voice catalogue and the shared pronunciation defaults, parsed from the exported asset. */
class VoiceCatalog(
    val voices: List<CloudVoice>,
    val pronunciationDefaults: List<PronunciationEntry>,
    val accountProviders: List<AccountVoiceProvider> = emptyList(),
    val realtime: RealtimeSpeechSpec? = null,
) {
    private val byKey = voices.associateBy { it.key }

    fun voice(key: String): CloudVoice? = byKey[key]

    /** The account provider and API identifier a saved [key] names, when it names an account voice. */
    fun accountVoice(key: String): Pair<AccountVoiceProvider, String>? =
        accountProviders.firstNotNullOfOrNull { provider -> provider.apiVoiceId(key)?.let { provider to it } }

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
            val accounts = root.optJSONArray("accountVoices")?.objects().orEmpty().map(::accountProvider)
            val realtime = root.optJSONObject("realtime")?.let(::realtime)
            return VoiceCatalog(voices, defaults, accounts, realtime)
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
            response = response(item.getString("response")),
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

        private fun response(name: String) = when (name) {
            "wav" -> VoiceResponse.Wav
            "geminiInteraction" -> VoiceResponse.GeminiInteraction
            "base64Wav" -> VoiceResponse.Base64Wav
            else -> error("Unknown voice response $name")
        }

        private fun accountProvider(item: JSONObject): AccountVoiceProvider {
            val list = item.getJSONObject("list")
            return AccountVoiceProvider(
                provider = item.getString("provider"),
                providerName = item.getString("providerName"),
                listing = item.getString("listing"),
                modelId = item.getString("modelID"),
                credentialId = item.getString("credentialID"),
                keyTemplate = item.getString("keyTemplate"),
                idTemplate = item.getString("idTemplate"),
                labelTemplate = item.getString("labelTemplate"),
                lowercaseVoiceId = item.getBoolean("lowercaseVoiceID"),
                fixedVoiceIds = item.getJSONArray("fixedVoiceIDs").let { array -> (0 until array.length()).map(array::getString) },
                readyModel = item.optStringOrNull("readyModel"),
                maxVoices = item.getInt("maxVoices"),
                list = AccountListRequest(
                    method = list.getString("method"),
                    url = list.getString("url"),
                    headers = list.getJSONObject("headers").strings(),
                    pageParameter = list.optStringOrNull("pageParameter"),
                    pageSize = if (list.has("pageSize")) list.getInt("pageSize") else null,
                    maxPages = list.getInt("maxPages"),
                    maxResponseBytes = list.getInt("maxResponseBytes"),
                    timeoutSeconds = list.getInt("timeoutSeconds"),
                ),
                sampleRate = item.getInt("sampleRate"),
                maxCharacters = item.getInt("maxCharacters"),
                maxSegments = if (item.has("maxSegments")) item.getInt("maxSegments") else null,
                response = response(item.getString("response")),
                audioField = item.optStringOrNull("audioField"),
                request = template(item.getJSONObject("request")),
            )
        }

        private fun realtime(item: JSONObject) = RealtimeSpeechSpec(
            provider = item.getString("provider"),
            providerName = item.getString("providerName"),
            displayName = item.getString("displayName"),
            modelId = item.getString("modelID"),
            credentialId = item.getString("credentialID"),
            url = item.getString("url"),
            headers = item.getJSONObject("headers").strings(),
            sessionUpdate = item.getJSONObject("sessionUpdate"),
            responseCreate = item.getJSONObject("responseCreate"),
            sampleRate = item.getInt("sampleRate"),
            chunkCharacters = item.getInt("chunkCharacters"),
            spokenWordsPerNumeral = item.getInt("spokenWordsPerNumeral"),
            responseTimeoutSeconds = item.getInt("responseTimeoutSeconds"),
            voices = item.getJSONArray("voices").objects().map { voice ->
                RealtimeVoice(
                    key = voice.getString("key"),
                    id = voice.getString("id"),
                    name = voice.getString("name"),
                    label = voice.getString("label"),
                    voice = voice.getString("voice"),
                )
            },
        )

        private fun JSONObject.strings(): Map<String, String> = keys().asSequence().associateWith(::getString)

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
