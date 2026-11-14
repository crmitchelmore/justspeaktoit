package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID

/**
 * Request and response formats for the batch providers that are not OpenAI-compatible. Each one
 * mirrors its shared SpeakCore client (`Sources/SpeakCore/Batch/Providers`) field for field. Pure,
 * so it is unit-tested; [BatchTranscriber] runs the requests.
 */
object BatchWire {
    /** A transcript of a long shared recording can exceed [CloudWire.MAX_RESPONSE_BYTES]. */
    const val MAX_RESPONSE_BYTES = 16 * 1024 * 1024

    /** `FileSpeechBatchClient.maximumAudioBytes`: Reson8 takes the recording in one request. */
    const val RESON8_MAX_AUDIO_BYTES = 25L * 1024 * 1024

    sealed interface Body {
        data object None : Body

        class Json(val text: String) : Body

        /** The recording itself is the body. */
        class Audio(val file: File) : Body

        /** The recording streamed between [Multipart.head] and [Multipart.tail]. */
        class Form(val multipart: CloudWire.Multipart, val file: File) : Body
    }

    class Request(
        val method: String,
        val url: String,
        val headers: Map<String, String>,
        val body: Body = Body.None,
    )

    class Response(val status: Int, val body: String) {
        val ok: Boolean get() = status in 200..299
    }

    // region Shared helpers

    /** `BatchTranscriptionJob.languageCode(from:)`: the first subtag, or null for Automatic. */
    fun languageCode(tag: String?): String? {
        val normalized = tag?.trim()?.lowercase(Locale.ROOT).orEmpty()
        if (normalized.isEmpty() || normalized == "auto" || normalized == "automatic") return null
        return normalized.split('-', '_').first().takeIf { it.isNotEmpty() }
    }

    /** The upstream model name: the catalogue ID's last component (`deepgram/nova-3` → `nova-3`). */
    fun modelName(catalogId: String): String = catalogId.substringAfterLast('/')

    /** Deepgram, ElevenLabs, Mistral and Rev AI label M4A as `audio/m4a`; the rest use `audio/mp4`. */
    fun uploadMimeType(format: SharedAudio.Format): String =
        if (format.extension == "m4a") "audio/m4a" else format.mimeType

    /** `TranscriptionKeywordPolicy.bounded`: trimmed, non-empty, at most [length] characters, distinct. */
    fun bounded(words: List<String>, count: Int, length: Int): List<String> {
        val seen = HashSet<String>()
        return words.asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.codePointCount(0, it.length) <= length && seen.add(it.lowercase()) }
            .take(count)
            .toList()
    }

    /** `TranscriptionKeywordPolicy.budgeted`: [bounded] terms whose UTF-8 bytes plus a separator fit. */
    fun budgeted(words: List<String>, maxBytes: Int): List<String> {
        var remaining = maxBytes
        return bounded(words, count = 100, length = 100).filter {
            val cost = it.toByteArray(Charsets.UTF_8).size + 1
            if (cost > remaining) {
                false
            } else {
                remaining -= cost
                true
            }
        }
    }

    fun query(base: String, items: List<Pair<String, String>>): String =
        base + "?" + items.joinToString("&") { (name, value) -> encode(name) + "=" + encode(value) }

    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

    private fun boundary(): String = "jsti-" + UUID.randomUUID()

    private fun form(
        fields: List<Pair<String, String>>,
        fileField: String,
        fileName: String,
        mimeType: String,
        audio: File,
        auth: Map<String, String>,
        url: String,
        trailingFields: List<Pair<String, String>> = emptyList(),
    ): Request {
        val multipart = CloudWire.multipart(fields, fileField, fileName, mimeType, boundary(), trailingFields)
        return Request("POST", url, auth + ("Content-Type" to multipart.contentType), Body.Form(multipart, audio))
    }

    // endregion

    // region Deepgram (`DeepgramBatchClient`)

    fun deepgramModel(catalogId: String): String = modelName(catalogId).removeSuffix("-streaming")

    /** `TranscriptionKeywordPolicy.deepgramQuery`: `keyterm` for Nova-3 and Flux, `keywords` for older models. */
    fun deepgramKeywords(model: String, vocabulary: List<String>): List<Pair<String, String>> {
        val name = when {
            model.startsWith("nova-3") || model.startsWith("flux-") -> "keyterm"
            model.startsWith("nova-2") || model in setOf("nova", "enhanced", "base") -> "keywords"
            else -> return emptyList()
        }
        return budgeted(vocabulary, maxBytes = 500).map { name to it }
    }

    fun deepgram(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request {
        val model = deepgramModel(catalogId)
        val items = mutableListOf("model" to model, "punctuate" to "true", "numerals" to "true", "utterances" to "true")
        languageCode(languageTag)?.let { items += "language" to it }
        items += deepgramKeywords(model, vocabulary)
        return Request(
            "POST",
            query("$baseUrl/listen", items),
            mapOf("Authorization" to "Token $apiKey", "Content-Type" to uploadMimeType(format)),
            Body.Audio(audio),
        )
    }

    /** `results.channels[0].alternatives[0].transcript`; empty when Deepgram heard nothing. */
    fun deepgramText(body: String): String = parse {
        val alternative = JSONObject(body).optJSONObject("results")
            ?.optJSONArray("channels")?.optJSONObject(0)
            ?.optJSONArray("alternatives")?.optJSONObject(0)
        alternative?.string("transcript").orEmpty()
    }

    // endregion

    // region AssemblyAI (`AssemblyAIBatchClient`)

    const val ASSEMBLYAI_UNIVERSAL_2 = "universal-2"
    const val ASSEMBLYAI_UNIVERSAL_35_PRO = "universal-3-5-pro"
    const val ASSEMBLYAI_POLL_MS = 1_000L
    const val ASSEMBLYAI_POLL_ATTEMPTS = 120

    fun assemblyAIUpload(baseUrl: String, apiKey: String, audio: File): Request = Request(
        "POST",
        "$baseUrl/upload",
        mapOf("Authorization" to apiKey, "Content-Type" to "application/octet-stream"),
        Body.Audio(audio),
    )

    fun assemblyAISpeechModels(catalogId: String): List<String> =
        when (modelName(catalogId).replace("-streaming", "")) {
            ASSEMBLYAI_UNIVERSAL_2 -> listOf(ASSEMBLYAI_UNIVERSAL_2)
            else -> listOf(ASSEMBLYAI_UNIVERSAL_35_PRO, ASSEMBLYAI_UNIVERSAL_2)
        }

    fun assemblyAISubmit(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        audioUrl: String,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request {
        val speechModels = assemblyAISpeechModels(catalogId)
        val json = JSONObject().put("audio_url", audioUrl).put("speech_models", JSONArray(speechModels))
        val terms = bounded(vocabulary, count = 100, length = 50)
        if (terms.isNotEmpty()) {
            if (ASSEMBLYAI_UNIVERSAL_35_PRO in speechModels) {
                json.put("keyterms_prompt", JSONArray(terms))
            } else if (speechModels == listOf(ASSEMBLYAI_UNIVERSAL_2)) {
                json.put("word_boost", JSONArray(terms))
            }
        }
        val language = languageCode(languageTag)
        if (language != null) json.put("language_code", language) else json.put("language_detection", true)
        return Request(
            "POST",
            "$baseUrl/transcript",
            mapOf("Authorization" to apiKey, "Content-Type" to "application/json"),
            Body.Json(json.toString()),
        )
    }

    fun assemblyAIPoll(baseUrl: String, apiKey: String, id: String): Request =
        Request("GET", "$baseUrl/transcript/${pathSegment(id)}", mapOf("Authorization" to apiKey))

    fun assemblyAIUploadUrl(body: String): String = parse { JSONObject(body).requireString("upload_url") }

    // endregion

    // region ElevenLabs (`ElevenLabsBatchClient`)

    /** `ElevenLabsLiveProtocol.boundedKeyterms`: no markup characters, at most five words, 49 characters. */
    fun elevenLabsKeyterms(vocabulary: List<String>): List<String> = bounded(
        vocabulary.filter { word ->
            word.none { it in "<>{}[]\\" } && word.split(Regex("\\s+")).count { it.isNotEmpty() } <= 5
        },
        count = 100,
        length = 49,
    )

    fun elevenLabs(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request {
        val model = modelName(catalogId)
        val fields = mutableListOf("model_id" to model, "timestamps_granularity" to "word")
        languageCode(languageTag)?.let { fields += "language_code" to it }
        if (model == "scribe_v2" || model == "scribe_v3") fields += elevenLabsKeyterms(vocabulary).map { "keyterms" to it }
        return form(
            fields, "file", "dictation.${format.extension}", uploadMimeType(format), audio,
            mapOf("xi-api-key" to apiKey), "$baseUrl/speech-to-text",
        )
    }

    // endregion

    // region Mistral (`MistralBatchClient`)

    /** `MistralBatchClient.supportsKeywords`: Voxtral Mini Latest and the Voxtral 3 batch models. */
    fun mistralSupportsKeywords(catalogId: String): Boolean {
        val name = modelName(catalogId)
        return name == "voxtral-mini-latest" || name in setOf("voxtral-mini-transcribe-3-0", "voxtral-small-transcribe-3-0")
    }

    fun mistral(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request {
        val fields = mutableListOf("model" to modelName(catalogId))
        languageCode(languageTag)?.let { fields += "language" to it }
        if (mistralSupportsKeywords(catalogId)) {
            fields += bounded(vocabulary, count = 100, length = 100).map { "context_bias" to it }
        }
        return form(
            fields, "file", "dictation.${format.extension}", uploadMimeType(format), audio,
            mapOf("Authorization" to "Bearer $apiKey"), "$baseUrl/audio/transcriptions",
        )
    }

    /**
     * Labelled segments when Voxtral diarised the recording; otherwise `text`, `transcription`, the
     * segments' text, then the words.
     */
    fun mistralText(body: String): String = parse {
        val json = JSONObject(body)
        val segments = json.optJSONArray("segments").objects()
        val labels = segments.map { mistralSpeaker(it.opt("speaker")) }
        if (labels.any { it != null }) {
            segments.mapIndexedNotNull { index, segment ->
                val text = segment.string("text") ?: return@mapIndexedNotNull null
                labels[index]?.let { "$it: $text" } ?: text
            }.joinToString("\n")
        } else {
            json.string("text")?.takeIf { it.isNotEmpty() }
                ?: json.string("transcription")?.takeIf { it.isNotEmpty() }
                ?: segments.mapNotNull { it.string("text") }.joinToString(" ").takeIf { it.isNotEmpty() }
                ?: json.optJSONArray("words").objects().mapNotNull { it.string("text") }.joinToString(" ")
        }
    }

    private fun mistralSpeaker(value: Any?): String? = when (value) {
        is Int -> "Speaker ${value + 1}"
        is Long -> "Speaker ${value + 1}"
        is String -> speakerLabel(value)
        else -> null
    }

    /** `SpeakerLabelNormalizer.displayLabel(for:spacedFormIsIndexed: false)`. */
    fun speakerLabel(value: String): String? {
        val raw = value.trim().takeIf { it.isNotEmpty() } ?: return null
        val upper = raw.uppercase(Locale.ROOT)
        return when {
            upper.startsWith("SPEAKER_") ->
                raw.filter { it.isDigit() }.toIntOrNull()?.let { "Speaker ${it + 1}" }
                    ?: capitalizeWords(raw.replace('_', ' '))
            upper.startsWith("SPEAKER ") -> capitalizeWords(raw)
            else -> raw
        }
    }

    private fun capitalizeWords(value: String): String = value.split(' ').joinToString(" ") { word ->
        word.lowercase(Locale.ROOT).replaceFirstChar { it.titlecase(Locale.ROOT) }
    }

    // endregion

    // region Rev AI (`RevAIBatchClient`)

    const val REVAI_POLL_MS = 2_000L
    const val REVAI_POLL_ATTEMPTS = 150

    fun revAISubmit(
        baseUrl: String,
        apiKey: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
    ): Request {
        val metadata = JSONObject()
        languageCode(languageTag)?.let { metadata.put("language", it) }
        metadata.put("skip_diarization", false).put("skip_punctuation", false)
        return form(
            listOf("metadata" to metadata.toString()), "media", "dictation.${format.extension}",
            uploadMimeType(format), audio, mapOf("Authorization" to "Bearer $apiKey"), "$baseUrl/jobs",
        )
    }

    fun revAIPoll(baseUrl: String, apiKey: String, id: String): Request =
        Request("GET", "$baseUrl/jobs/${pathSegment(id)}", mapOf("Authorization" to "Bearer $apiKey"))

    fun revAITranscript(baseUrl: String, apiKey: String, id: String): Request = Request(
        "GET",
        "$baseUrl/jobs/${pathSegment(id)}/transcript",
        mapOf("Authorization" to "Bearer $apiKey", "Accept" to "application/vnd.rev.transcript.v1.0+json"),
    )

    /** Every element's value, joined with spaces exactly as the shared client does. */
    fun revAIText(body: String): String = parse {
        JSONObject(body).optJSONArray("monologues").objects()
            .flatMap { it.optJSONArray("elements").objects() }
            .mapNotNull { it.string("value") }
            .joinToString(" ")
    }

    // endregion

    // region Soniox (`SonioxBatchClient`)

    const val SONIOX_POLL_MS = 2_000L
    const val SONIOX_POLL_ATTEMPTS = 90

    fun sonioxUpload(baseUrl: String, apiKey: String, audio: File, format: SharedAudio.Format): Request = form(
        emptyList(), "file", "dictation.${format.extension}", format.mimeType, audio,
        mapOf("Authorization" to "Bearer $apiKey"), "$baseUrl/files",
    )

    fun sonioxCreate(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        fileId: String,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request {
        val json = JSONObject()
        val terms = budgeted(vocabulary, maxBytes = 7_500)
        if (terms.isNotEmpty()) json.put("context", JSONObject().put("terms", JSONArray(terms)))
        json.put("model", modelName(catalogId)).put("file_id", fileId)
        languageCode(languageTag)?.let { json.put("language_hints", JSONArray(listOf(it))) }
        json.put("enable_speaker_diarization", true).put("enable_language_identification", true)
        return Request(
            "POST",
            "$baseUrl/transcriptions",
            mapOf("Authorization" to "Bearer $apiKey", "Content-Type" to "application/json"),
            Body.Json(json.toString()),
        )
    }

    fun sonioxGet(baseUrl: String, apiKey: String, path: String): Request =
        Request("GET", "$baseUrl/$path", mapOf("Authorization" to "Bearer $apiKey"))

    fun sonioxDelete(baseUrl: String, apiKey: String, path: String): Request =
        Request("DELETE", "$baseUrl/$path", mapOf("Authorization" to "Bearer $apiKey"))

    /**
     * Consecutive tokens grouped by speaker and language, one labelled line each, when the recording
     * has more than one; otherwise the plain `text`.
     */
    fun sonioxText(body: String): String = parse {
        val json = JSONObject(body)
        val tokens = json.optJSONArray("tokens").objects().map { (it.string("text") ?: "") to sonioxKey(it) }
        if (tokens.map { it.second }.toSet().size <= 1) {
            json.requireString("text")
        } else {
            val lines = mutableListOf<Pair<String, StringBuilder>>()
            for ((text, key) in tokens) {
                if (lines.lastOrNull()?.first == key) lines.last().second.append(text) else lines += key to StringBuilder(text)
            }
            lines.joinToString("\n") { (key, text) -> if (key.isEmpty()) text.toString() else "$key: $text" }
        }
    }

    private fun sonioxKey(token: JSONObject): String {
        val speaker = token.string("speaker")?.trim().orEmpty()
        val language = token.string("language")?.trim().orEmpty()
        return when {
            speaker.isEmpty() -> if (language.isEmpty()) "" else "Language $language"
            language.isEmpty() -> "Speaker $speaker"
            else -> "Speaker $speaker [$language]"
        }
    }

    // endregion

    // region Speechmatics (`SpeechmaticsBatchClient`)

    const val SPEECHMATICS_STANDARD = "speechmatics/standard"
    const val SPEECHMATICS_POLL_MS = 2_000L
    const val SPEECHMATICS_TIMEOUT_MS = 900_000L

    fun speechmaticsConfig(catalogId: String, languageTag: String?, vocabulary: List<String>): String {
        val transcription = JSONObject()
            .put("language", languageCode(languageTag) ?: "auto")
            .put("operating_point", if (catalogId == SPEECHMATICS_STANDARD) "standard" else "enhanced")
        val terms = bounded(vocabulary, count = 100, length = 100)
        if (terms.isNotEmpty()) {
            transcription.put("additional_vocab", JSONArray(terms.map { JSONObject().put("content", it) }))
        }
        return JSONObject().put("type", "transcription").put("transcription_config", transcription).toString()
    }

    fun speechmaticsSubmit(
        baseUrl: String,
        catalogId: String,
        apiKey: String,
        audio: File,
        format: SharedAudio.Format,
        languageTag: String?,
        vocabulary: List<String>,
    ): Request = form(
        listOf("config" to speechmaticsConfig(catalogId, languageTag, vocabulary)), "data_file",
        "recording.${format.extension}", format.mimeType, audio,
        mapOf("Authorization" to "Bearer $apiKey"), "$baseUrl/v2/jobs",
    )

    fun speechmaticsPoll(baseUrl: String, apiKey: String, id: String): Request =
        Request("GET", "$baseUrl/v2/jobs/${pathSegment(id)}", mapOf("Authorization" to "Bearer $apiKey"))

    fun speechmaticsTranscript(baseUrl: String, apiKey: String, id: String): Request = Request(
        "GET",
        query("$baseUrl/v2/jobs/${pathSegment(id)}/transcript", listOf("format" to "json-v2")),
        mapOf("Authorization" to "Bearer $apiKey"),
    )

    fun speechmaticsDelete(baseUrl: String, apiKey: String, id: String): Request = Request(
        "DELETE",
        query("$baseUrl/v2/jobs/${pathSegment(id)}", listOf("force" to "true")),
        mapOf("Authorization" to "Bearer $apiKey"),
    )

    /** True when the job is done; throws when Speechmatics rejected, deleted or expired it. */
    fun speechmaticsDone(body: String): Boolean {
        val job = try {
            JSONObject(body).getJSONObject("job")
        } catch (e: JSONException) {
            throw CloudException(DictationFailure.Server, "Unexpected response", e)
        }
        return when (val status = job.string("status")) {
            "done" -> true
            "rejected", "deleted", "expired" -> {
                val message = job.optJSONArray("errors").objects().mapNotNull { it.string("message") }.joinToString("; ")
                throw CloudException(DictationFailure.Server, "Speechmatics job $status: ${message.ifEmpty { status }}")
            }
            null -> throw CloudException(DictationFailure.Server, "Missing status")
            else -> false
        }
    }

    /**
     * `json-v2` items: punctuation attaches to the previous word without a space, unless it attaches
     * to the next one (an opening bracket), which takes the space before it instead.
     */
    fun speechmaticsText(body: String): String = parse {
        val items = JSONObject(body).getJSONArray("results").objects()
        val text = StringBuilder()
        var attachesToFollowing = false
        for (item in items) {
            val content = item.optJSONArray("alternatives")?.optJSONObject(0)?.string("content") ?: continue
            val isPunctuation = item.string("type") == "punctuation"
            if (isPunctuation && item.string("attaches_to") != "next") {
                text.append(content)
                continue
            }
            if (text.isNotEmpty() && !attachesToFollowing) text.append(' ')
            text.append(content)
            attachesToFollowing = isPunctuation
        }
        text.toString()
    }

    // endregion

    // region Modulate (`ModulateBatchClient`)

    private const val MODULATE_FAST = "velma-2-stt-batch-english-vfast"

    fun modulateIsEnglishFast(catalogId: String): Boolean = catalogId.endsWith(MODULATE_FAST)

    /** `ModulateTranscriptionFeatures()` defaults, sent after the file on the multilingual model only. */
    val MODULATE_FEATURES = listOf(
        "speaker_diarization" to "true",
        "emotion_signal" to "false",
        "accent_signal" to "false",
        "pii_phi_tagging" to "false",
    )

    /** Modulate takes no language: the multilingual model detects it, the fast one is English only. */
    fun modulate(baseUrl: String, catalogId: String, apiKey: String, audio: File, format: SharedAudio.Format): Request {
        val fast = modulateIsEnglishFast(catalogId)
        return form(
            emptyList(), "upload_file", "dictation.${format.extension}", format.mimeType, audio,
            mapOf("X-API-Key" to apiKey),
            if (fast) "$baseUrl/api/$MODULATE_FAST" else "$baseUrl/api/velma-2-stt-batch",
            trailingFields = if (fast) emptyList() else MODULATE_FEATURES,
        )
    }

    /** `Speaker N: text` lines when the multilingual model heard more than one speaker; else `text`. */
    fun modulateText(body: String, catalogId: String): String = parse {
        val json = JSONObject(body)
        val utterances = json.optJSONArray("utterances").objects()
        val speakers = utterances.map { it.optInt("speaker") }
        if (!modulateIsEnglishFast(catalogId) && speakers.toSet().size > 1) {
            utterances.joinToString("\n") { "Speaker ${it.optInt("speaker")}: ${it.string("text").orEmpty()}" }
        } else {
            json.requireString("text")
        }
    }

    // endregion

    // region Reson8 (`FileSpeechBatchClient`)

    const val RESON8_URL = "https://api.reson8.dev/v1/speech-to-text/prerecorded"

    /**
     * The model's language hint, or null for Automatic.
     * @throws CloudException ([DictationFailure.LanguageNotSupported]) for a language the model lacks.
     */
    fun reson8Language(model: CloudModel, languageTag: String?): String? {
        val code = languageCode(languageTag) ?: return null
        val supported = model.languageCodes ?: return code
        if (code !in supported) {
            throw CloudException(DictationFailure.LanguageNotSupported, "${model.displayName} does not support $code")
        }
        return code
    }

    fun reson8(model: CloudModel, apiKey: String, audio: File, format: SharedAudio.Format, languageTag: String?): Request {
        val items = mutableListOf(
            "model" to modelName(model.catalogId).removeSuffix("-streaming"),
            "include_timestamps" to "true",
            "include_words" to "true",
            "include_confidence" to "true",
        )
        reson8Language(model, languageTag)?.let { items += "language" to it }
        if (format.extension == "m4a") items += "encoding" to "m4a"
        return Request(
            "POST",
            query(RESON8_URL, items),
            mapOf(
                "Authorization" to "ApiKey $apiKey",
                "Content-Type" to "application/octet-stream",
                "Accept" to "application/json",
            ),
            Body.Audio(audio),
        )
    }

    // endregion

    // region JSON

    /** A required string field of a response (`id`, `upload_url`, `text`, ...). */
    fun requiredString(body: String, name: String): String = parse { JSONObject(body).requireString(name) }

    /** An optional string field, for job status values. */
    fun optionalString(body: String, name: String): String? = try {
        JSONObject(body).string(name)
    } catch (e: JSONException) {
        throw CloudException(DictationFailure.Server, "Unexpected response", e)
    }

    /** One path segment of a provider-issued ID, percent-encoded. */
    fun pathSegment(segment: String): String = encode(segment).replace("+", "%20")

    // Android's getString() coerces null, numbers and objects to text; only a real string counts.
    private fun JSONObject.string(name: String): String? = opt(name) as? String

    private fun JSONObject.requireString(name: String): String =
        string(name) ?: throw CloudException(DictationFailure.Server, "Missing $name")

    private fun JSONArray?.objects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

    private inline fun parse(block: () -> String): String = try {
        block().trim()
    } catch (e: JSONException) {
        throw CloudException(DictationFailure.Server, "Unexpected response", e)
    }

    // endregion
}
