package com.justspeaktoit.android.cloud

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.math.BigDecimal
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/**
 * SpeakCore's `CleanupModelSelection`: a discovered cleanup model is saved as
 * `openrouter/cleanup/openai/<model>`, a namespace that outlives the discovery cache. Only OpenAI
 * models with a plain lowercase slug are trusted.
 */
object OpenRouterCleanupSelection {
    const val PREFIX = "openrouter/cleanup/"

    fun selectionId(modelId: String): String = PREFIX + modelId

    fun modelId(selection: String?): String? {
        if (selection == null || !selection.startsWith(PREFIX)) return null
        return selection.removePrefix(PREFIX).takeIf(::isTrusted)
    }

    fun isTrusted(model: String): Boolean {
        val parts = model.split('/')
        return model.toByteArray(Charsets.UTF_8).size <= 200 && parts.size == 2 && parts[0] == "openai" &&
            parts[1].isNotEmpty() && parts[1].all { it in 'a'..'z' || it in '0'..'9' || it in "-._" }
    }
}

/**
 * SpeakCore's `OpenRouterTranscriptionSelection`: a live speech-to-text model is saved as
 * `openrouter/transcription/<vendor>/<model>`.
 */
object OpenRouterTranscriptionSelection {
    const val PREFIX = "openrouter/transcription/"

    fun selectionId(modelId: String): String = PREFIX + modelId

    fun modelId(selection: String?): String? {
        if (selection == null || !selection.startsWith(PREFIX)) return null
        return selection.removePrefix(PREFIX).takeIf(::isValidModelId)
    }

    fun isValidModelId(modelId: String): Boolean {
        val parts = modelId.split('/')
        return modelId.toByteArray(Charsets.UTF_8).size <= 512 && parts.size >= 2 && parts.all { it.isNotEmpty() } &&
            modelId.none { it.isWhitespace() || Character.isISOControl(it) }
    }
}

/** SpeakCore's `DiscoveredCleanupModel`: validated metadata only; descriptions are discarded. */
data class DiscoveredCleanupModel(
    val id: String,
    val name: String,
    /** Dollars per million input tokens, when listed and plausible. */
    val inputPrice: Double?,
    val outputPrice: Double?,
    val contextLength: Int?,
) {
    val selectionId: String get() = OpenRouterCleanupSelection.selectionId(id)

    val isValid: Boolean
        get() = OpenRouterCleanupSelection.isTrusted(id) && name.isNotEmpty() &&
            name.toByteArray(Charsets.UTF_8).size <= 160 && name.none(Character::isISOControl) &&
            listOf(inputPrice, outputPrice).all { price -> price == null || (price.isFinite() && price in 0.0..1_000_000.0) } &&
            (contextLength == null || contextLength in 1..100_000_000)
}

/** SpeakCore's `OpenRouterAudioModel`, limited to what the transcription browser shows. */
data class OpenRouterAudioModel(
    val id: String,
    val name: String,
    val description: String,
    val inputModalities: List<String>,
    val outputModalities: List<String>,
    /** The provider's own keys and decimal strings; units vary by model. */
    val pricing: Map<String, String>,
    val contextLength: Int?,
) {
    val transcriptionSelectionId: String get() = OpenRouterTranscriptionSelection.selectionId(id)
    val supportsTranscription: Boolean get() = TRANSCRIPTION in outputModalities

    internal fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("description", description)
        .put(
            "architecture",
            JSONObject()
                .put("input_modalities", JSONArray(inputModalities))
                .put("output_modalities", JSONArray(outputModalities)),
        )
        .put("pricing", JSONObject(pricing))
        .apply { contextLength?.let { put("context_length", it) } }

    companion object {
        const val TRANSCRIPTION = "transcription"
        internal val CAPABILITIES = setOf(TRANSCRIPTION, "speech")
    }
}

/** A response the discovery parsers reject; a good cache is kept. */
class OpenRouterDiscoveryException(message: String) : Exception(message)

/**
 * Live OpenRouter model discovery, matching SpeakCore's `CleanupModelDiscovery` and
 * `OpenRouterAudioCatalog` rules field for field. Pure, so it is unit-tested against the fixtures the
 * Swift tests share (`Tests/Fixtures/openrouter-browser`).
 */
object OpenRouterDiscovery {
    const val CLEANUP_MODELS_URL = GeneratedCloudCatalog.OPENROUTER_CLEANUP_MODELS_URL
    const val TRANSCRIPTION_MODELS_URL = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_MODELS_URL
    const val CACHE_LIFETIME_MILLIS = 6L * 60 * 60 * 1000
    const val MAX_CACHE_AGE_MILLIS = 7L * 24 * 60 * 60 * 1000
    const val RETRY_FLOOR_MILLIS = 60_000L
    const val MAX_BYTES = 4 * 1024 * 1024
    const val FAILURE = "Discovery unavailable. Bundled models and your saved selection are kept."
    private const val MAX_ENTRIES = 4096
    private const val MAX_CLEANUP_MODELS = 256
    private const val CACHE_VERSION = 1
    private val DECIMAL = Regex("^[+-]?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")

    // region Cleanup

    /** `GET /api/v1/models` filtered to OpenAI text models that chat completions can run. */
    fun parseCleanup(body: String): List<DiscoveredCleanupModel> {
        val data = parseObject(body).opt("data") as? JSONArray ?: throw invalid()
        if (data.length() > MAX_ENTRIES) throw invalid()
        val seen = mutableSetOf<String>()
        return (0 until data.length())
            .mapNotNull { cleanupEntry(data.opt(it) as? JSONObject) }
            .filter { seen.add(it.id) }
            .sortedBy { it.id }
            .take(MAX_CLEANUP_MODELS)
    }

    private fun cleanupEntry(entry: JSONObject?): DiscoveredCleanupModel? {
        entry ?: return null
        val id = entry.opt("id") as? String ?: return null
        val architecture = entry.opt("architecture") as? JSONObject ?: return null
        val input = strings(architecture.opt("input_modalities")) ?: return null
        val output = strings(architecture.opt("output_modalities")) ?: return null
        val endpoints = strings(entry.opt("endpoints")) ?: return null
        val expiration = entry.opt("expiration_date")
        if (!OpenRouterCleanupSelection.isTrusted(id) || "text" !in input || output != listOf("text") ||
            "/api/v1/chat/completions" !in endpoints || (expiration != null && expiration != JSONObject.NULL)
        ) {
            return null
        }
        val pricing = entry.opt("pricing") as? JSONObject
        val prompt = pricing?.opt("prompt")
        val completion = pricing?.opt("completion")
        // SpeakCore decodes both rates together: a non-string rate drops both.
        val ratesReadable = listOf(prompt, completion).all { it == null || it == JSONObject.NULL || it is String }
        val model = DiscoveredCleanupModel(
            id = id,
            name = entry.opt("name") as? String ?: id,
            inputPrice = if (ratesReadable) perMillion(prompt as? String) else null,
            outputPrice = if (ratesReadable) perMillion(completion as? String) else null,
            contextLength = positiveInt(entry.opt("context_length")),
        )
        return model.takeIf { it.isValid }
    }

    /** A per-token rate as dollars per million tokens; implausible rates are unlisted. */
    internal fun perMillion(text: String?): Double? {
        val value = text?.toDoubleOrNull() ?: return null
        if (!value.isFinite() || value < 0 || value > 1) return null
        return try {
            BigDecimal(text).multiply(BigDecimal(1_000_000)).toDouble()
        } catch (e: NumberFormatException) {
            null
        }
    }

    /** SpeakCore's `ModelCatalog.Pricing.displayName`, for example `$0.10/$0.50 / 1M`. */
    fun pricingDisplay(input: Double?, output: Double?): String? {
        if (input == null || output == null) return null
        return "${dollars(input)}/${dollars(output)} / 1M"
    }

    private fun dollars(value: Double): String = when {
        value >= 10 -> String.format(Locale.US, "$%.0f", value)
        value >= 0.1 -> String.format(Locale.US, "$%.2f", value)
        value > 0 -> String.format(Locale.US, "$%.3f", value)
        else -> "$0"
    }

    // endregion

    // region Transcription

    /**
     * `GET /api/v1/models?output_modalities=transcription`: dedicated audio models, deduplicated. Entries
     * that cannot be read are skipped, but a non-empty list with nothing usable is rejected so that an
     * ignored filter cannot erase a good cache.
     */
    fun parseTranscription(body: String): List<OpenRouterAudioModel> =
        parseTranscriptionData(parseObject(body).opt("data") as? JSONArray ?: throw invalid())

    internal fun parseTranscriptionData(data: JSONArray): List<OpenRouterAudioModel> {
        if (data.length() > MAX_ENTRIES) throw invalid()
        val seen = mutableSetOf<String>()
        val models = (0 until data.length())
            .mapNotNull { audioEntry(data.opt(it) as? JSONObject) }
            .filter { model -> model.outputModalities.any { it in OpenRouterAudioModel.CAPABILITIES } && seen.add(model.id) }
        if (data.length() > 0 && models.isEmpty()) throw invalid()
        return models
    }

    private fun audioEntry(entry: JSONObject?): OpenRouterAudioModel? {
        entry ?: return null
        val id = entry.opt("id") as? String ?: return null
        if (!OpenRouterTranscriptionSelection.isValidModelId(id)) return null
        val architecture = entry.opt("architecture") as? JSONObject ?: return null
        val input = strings(architecture.opt("input_modalities")) ?: return null
        val output = strings(architecture.opt("output_modalities")) ?: return null
        val pricing = (entry.opt("pricing") as? JSONObject)?.let { prices ->
            prices.keys().asSequence().mapNotNull { key -> (prices.opt(key) as? String)?.let { key to it } }.toMap()
        } ?: emptyMap()
        return OpenRouterAudioModel(
            id = id,
            name = (entry.opt("name") as? String)?.takeIf { it.isNotEmpty() } ?: id,
            description = entry.opt("description") as? String ?: "",
            inputModalities = input,
            outputModalities = output,
            pricing = pricing,
            contextLength = positiveInt(entry.opt("context_length")),
        )
    }

    /** SpeakCore's `OpenRouterAudioFilter.hasZeroPrices`: every listed price is a decimal zero. */
    fun hasZeroPrices(pricing: Map<String, String>): Boolean =
        pricing.isNotEmpty() && pricing.values.all { value ->
            DECIMAL.matches(value) && runCatching { BigDecimal(value).signum() == 0 }.getOrDefault(false)
        }

    /**
     * A saved `openrouter/transcription/…` model that a loaded live catalogue no longer lists. It is shown
     * as unavailable, never silently replaced.
     */
    fun missingTranscriptionSelection(
        selection: String?,
        discovered: List<OpenRouterAudioModel>,
        catalogueLoaded: Boolean,
    ): String? {
        if (!catalogueLoaded) return null
        val id = OpenRouterTranscriptionSelection.modelId(selection) ?: return null
        return id.takeUnless { discovered.any { it.supportsTranscription && it.id == id } }
    }

    // endregion

    // region Cache

    /** A cache read back: its models and when they were downloaded. */
    data class Cached<T>(val models: List<T>, val updatedAt: Long)

    fun encodeCleanupCache(models: List<DiscoveredCleanupModel>, updatedAt: Long): String =
        cacheEnvelope(updatedAt).put(
            "models",
            JSONArray(
                models.map { model ->
                    JSONObject()
                        .put("id", model.id)
                        .put("name", model.name)
                        .apply {
                            model.inputPrice?.let { put("inputPrice", it) }
                            model.outputPrice?.let { put("outputPrice", it) }
                            model.contextLength?.let { put("contextLength", it) }
                        }
                },
            ),
        ).toString()

    /** Null for an unreadable, future-dated or expired cache; invalid rows are dropped. */
    fun decodeCleanupCache(text: String, now: Long): Cached<DiscoveredCleanupModel>? {
        val json = cacheEnvelope(text, now) ?: return null
        val rows = json.opt("models") as? JSONArray ?: return null
        val models = (0 until rows.length()).mapNotNull { index ->
            val row = rows.opt(index) as? JSONObject ?: return@mapNotNull null
            DiscoveredCleanupModel(
                id = row.opt("id") as? String ?: return@mapNotNull null,
                name = row.opt("name") as? String ?: return@mapNotNull null,
                inputPrice = (row.opt("inputPrice") as? Number)?.toDouble(),
                outputPrice = (row.opt("outputPrice") as? Number)?.toDouble(),
                contextLength = positiveInt(row.opt("contextLength")),
            ).takeIf { it.isValid }
        }.distinctBy { it.id }.take(MAX_CLEANUP_MODELS)
        return Cached(models, json.getLong("updatedAt"))
    }

    fun encodeTranscriptionCache(models: List<OpenRouterAudioModel>, updatedAt: Long): String =
        cacheEnvelope(updatedAt).put("data", JSONArray(models.map { it.toJson() })).toString()

    fun decodeTranscriptionCache(text: String, now: Long): Cached<OpenRouterAudioModel>? {
        val json = cacheEnvelope(text, now) ?: return null
        val data = json.opt("data") as? JSONArray ?: return null
        val models = try {
            parseTranscriptionData(data)
        } catch (e: OpenRouterDiscoveryException) {
            return null
        }
        return Cached(models, json.getLong("updatedAt"))
    }

    private fun cacheEnvelope(updatedAt: Long): JSONObject =
        JSONObject().put("version", CACHE_VERSION).put("updatedAt", updatedAt)

    private fun cacheEnvelope(text: String, now: Long): JSONObject? {
        val json = try {
            JSONObject(text)
        } catch (e: JSONException) {
            return null
        }
        if (json.optInt("version", -1) != CACHE_VERSION) return null
        val updatedAt = (json.opt("updatedAt") as? Number)?.toLong() ?: return null
        if (updatedAt > now || now - updatedAt > MAX_CACHE_AGE_MILLIS) return null
        return json
    }

    // endregion

    // region Network

    /** Public metadata only: no key, cookie or transcript is sent. */
    fun download(url: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Cache-Control", "no-store")
            val status = connection.responseCode
            if (status !in 200..299) {
                throw CloudException(CloudWire.failureForStatus(status), "OpenRouter discovery returned $status")
            }
            return connection.inputStream.use { CloudWire.readBody(it, MAX_BYTES) }
        } finally {
            connection.disconnect()
        }
    }

    // endregion

    private fun parseObject(body: String): JSONObject = try {
        JSONObject(body)
    } catch (e: JSONException) {
        throw invalid()
    }

    private fun invalid() = OpenRouterDiscoveryException("Unexpected OpenRouter model list")

    private fun strings(value: Any?): List<String>? {
        val array = value as? JSONArray ?: return null
        return (0 until array.length()).map { array.opt(it) as? String ?: return null }
    }

    /** An integer above zero; fractions and zero are unlisted. */
    private fun positiveInt(value: Any?): Int? = when (value) {
        is Int -> value
        is Long -> value.takeIf { it <= Int.MAX_VALUE }?.toInt()
        else -> null
    }?.takeIf { it > 0 }
}

/** What discovery has found and whether a request is running or failed. */
data class OpenRouterDiscoveryState(
    val transcriptionModels: List<OpenRouterAudioModel> = emptyList(),
    /** A live catalogue (downloaded or cached) is loaded, so a missing saved model is known to be gone. */
    val transcriptionLoaded: Boolean = false,
    val transcriptionLoading: Boolean = false,
    val transcriptionFailed: Boolean = false,
    val cleanupModels: List<DiscoveredCleanupModel> = emptyList(),
    val cleanupLoading: Boolean = false,
    val cleanupFailed: Boolean = false,
)

/**
 * Android's discovery store, matching SpeakCore's `CleanupModelDiscoveryStore` and the transcription
 * browser's catalogue: caches are read on first use, a fresh cache (six hours) skips the network unless
 * refreshed by hand, a cache older than seven days or dated in the future is ignored, and requests are
 * at least a minute apart. A failure keeps the cache and the bundled models. Every call comes from
 * [scope]'s thread; file and network work runs on [io].
 */
class OpenRouterDiscoveryStore(
    private val cacheDir: File,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val fetch: (String) -> String = OpenRouterDiscovery::download,
    private val clock: () -> Long = System::currentTimeMillis,
    private val publish: (OpenRouterDiscoveryState) -> Unit,
) {
    private var state = OpenRouterDiscoveryState()
    private var cacheLoad: Job? = null
    private var cleanupEnabled = false
    private var transcriptionUpdatedAt: Long? = null
    private var cleanupUpdatedAt: Long? = null
    private var transcriptionAttempt: Long? = null
    private var cleanupAttempt: Long? = null
    private var transcriptionJob: Job? = null
    private var cleanupJob: Job? = null

    private val transcriptionCache get() = File(cacheDir, "openrouter-transcription-models.json")
    private val cleanupCache get() = File(cacheDir, "openrouter-cleanup-models.json")

    val current: OpenRouterDiscoveryState get() = state

    /** The browser opened or Refresh was pressed. */
    fun refreshTranscription(force: Boolean = false) {
        if (transcriptionJob != null) return
        transcriptionJob = launch {
            readCaches()
            val started = clock()
            if (!due(force, transcriptionUpdatedAt, transcriptionAttempt, started)) return@launch
            transcriptionAttempt = started
            update { it.copy(transcriptionLoading = true, transcriptionFailed = false) }
            val result = download(OpenRouterDiscovery.TRANSCRIPTION_MODELS_URL) { body ->
                OpenRouterDiscovery.parseTranscription(body).also { models ->
                    write(transcriptionCache, OpenRouterDiscovery.encodeTranscriptionCache(models, clock()))
                }
            }
            if (result != null) transcriptionUpdatedAt = clock()
            update {
                it.copy(
                    transcriptionModels = result ?: it.transcriptionModels,
                    transcriptionLoaded = it.transcriptionLoaded || result != null,
                    transcriptionLoading = false,
                    transcriptionFailed = result == null,
                )
            }
        }.also { job -> job.invokeOnCompletion { if (transcriptionJob === job) transcriptionJob = null } }
        transcriptionJob?.start()
    }

    /** Cleanup discovery is opt-in; turning it off drops a running request but keeps the cache. */
    fun setCleanupEnabled(enabled: Boolean) {
        cleanupEnabled = enabled
        if (!enabled) {
            cleanupJob?.cancel()
            cleanupJob = null
            update { it.copy(cleanupLoading = false, cleanupFailed = false) }
        } else {
            refreshCleanup()
        }
    }

    fun refreshCleanup(force: Boolean = false) {
        if (!cleanupEnabled || cleanupJob != null) return
        cleanupJob = launch {
            readCaches()
            val started = clock()
            if (!due(force, cleanupUpdatedAt, cleanupAttempt, started)) return@launch
            cleanupAttempt = started
            update { it.copy(cleanupLoading = true, cleanupFailed = false) }
            val result = download(OpenRouterDiscovery.CLEANUP_MODELS_URL) { body ->
                OpenRouterDiscovery.parseCleanup(body).also { models ->
                    write(cleanupCache, OpenRouterDiscovery.encodeCleanupCache(models, clock()))
                }
            }
            if (!cleanupEnabled) return@launch
            if (result != null) cleanupUpdatedAt = clock()
            update {
                it.copy(
                    cleanupModels = result ?: it.cleanupModels,
                    cleanupLoading = false,
                    cleanupFailed = result == null,
                )
            }
        }.also { job -> job.invokeOnCompletion { if (cleanupJob === job) cleanupJob = null } }
        cleanupJob?.start()
    }

    /** Reads the caches without the network, so saved discovered names resolve before any refresh. */
    fun restore() {
        cacheLoad()
    }

    // Lazy, so the job is registered before it can finish on an immediate dispatcher.
    private fun launch(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(start = CoroutineStart.LAZY, block = block)

    private fun due(force: Boolean, updatedAt: Long?, attempt: Long?, now: Long): Boolean {
        if (attempt != null && now - attempt < OpenRouterDiscovery.RETRY_FLOOR_MILLIS) return false
        return force || updatedAt == null || now - updatedAt >= OpenRouterDiscovery.CACHE_LIFETIME_MILLIS
    }

    // One shared read, so a refresh that starts while restore() is reading waits for the cache.
    private suspend fun readCaches() = cacheLoad().join()

    private fun cacheLoad(): Job = cacheLoad ?: scope.launch { loadCaches() }.also { cacheLoad = it }

    private suspend fun loadCaches() {
        val now = clock()
        val (transcription, cleanup) = withContext(io) {
            read(transcriptionCache)?.let { OpenRouterDiscovery.decodeTranscriptionCache(it, now) } to
                read(cleanupCache)?.let { OpenRouterDiscovery.decodeCleanupCache(it, now) }
        }
        transcriptionUpdatedAt = transcription?.updatedAt
        cleanupUpdatedAt = cleanup?.updatedAt
        update {
            it.copy(
                transcriptionModels = transcription?.models ?: it.transcriptionModels,
                transcriptionLoaded = it.transcriptionLoaded || transcription != null,
                cleanupModels = cleanup?.models ?: it.cleanupModels,
            )
        }
    }

    /** The parsed models, or null after any failure; cancellation still propagates. */
    private suspend fun <T> download(url: String, parse: (String) -> T): T? = withContext(io) {
        try {
            parse(fetch(url))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
    }

    private fun read(file: File): String? = try {
        file.takeIf { it.isFile && it.length() <= OpenRouterDiscovery.MAX_BYTES }?.readText()
    } catch (e: java.io.IOException) {
        null
    }

    private fun write(file: File, text: String) {
        try {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeText(text)
            if (!temporary.renameTo(file)) temporary.delete()
        } catch (e: java.io.IOException) {
            // A cache that cannot be written only costs a download next time.
        }
    }

    private fun update(change: (OpenRouterDiscoveryState) -> OpenRouterDiscoveryState) {
        val next = change(state)
        if (next == state) return
        state = next
        CloudCatalog.rememberDiscoveredNames(
            cleanup = next.cleanupModels.associate { it.id to it.name },
            transcription = next.transcriptionModels.associate { it.id to it.name },
        )
        publish(next)
    }
}
