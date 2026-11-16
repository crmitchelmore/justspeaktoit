package com.justspeaktoit.android.cloud

import java.util.Locale

/** A provider row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class CloudProviderSpec(val id: String, val credentialId: String)

/** A cleanup model row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class CleanupModelSpec(
    val selectionId: String,
    val displayName: String,
    val providerId: String,
    val apiName: String,
)

/** A transcription model row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class CloudModelSpec(
    val catalogId: String,
    val displayName: String,
    val providerId: String,
    val apiName: String,
    val languageField: String,
    val supportsPrompt: Boolean,
    val languageCodes: List<String>?,
    val languageHints: Map<String, String>?,
    val requiresPCM16WAV: Boolean,
)

/** A live (streaming) transcription row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class LiveModelSpec(
    val catalogId: String,
    val displayName: String,
    val providerId: String,
    val apiName: String,
    val sampleRate: Int,
    val languageField: String,
    val vocabularyField: String,
    val postStopFinalizeBudgetMs: Int,
)

/** A language row of `assets/cloud_catalog.json` (SpeakCore's `TranscriptionLanguageCatalog`). */
internal data class TranscriptionLanguageSpec(val id: String, val displayName: String)

/**
 * How Android reaches each provider: its display name and base URL are transport details the shared
 * catalogue does not own. Which providers exist, their order and credential IDs come from
 * [GeneratedCloudCatalog]; `CloudCatalogParityTest` fails if a generated provider has no transport
 * here or a transport has no generated provider.
 */
enum class CloudProvider(val id: String, val displayName: String, val baseUrl: String) {
    OpenAI("openai", "OpenAI", "https://api.openai.com/v1"),
    Groq("groq", "Groq", "https://api.groq.com/openai/v1"),
    OpenRouter("openrouter", "OpenRouter", "https://openrouter.ai/api/v1"),
    Anthropic("anthropic", "Anthropic", "https://api.anthropic.com/v1"),
    Google("google", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
    Mistral("mistral", "Mistral", "https://api.mistral.ai/v1"),
    AssemblyAI("assemblyai", "AssemblyAI", "https://api.assemblyai.com/v2"),
    Deepgram("deepgram", "Deepgram", "https://api.deepgram.com/v1"),
    ElevenLabs("elevenlabs", "ElevenLabs", "https://api.elevenlabs.io/v1"),
    Modulate("modulate", "Modulate", "https://platform.modulate.ai"),
    Reson8("reson8", "Reson8", "https://api.reson8.dev/v1"),
    RevAI("revai", "Rev AI", "https://api.rev.ai/speechtotext/v1"),
    Soniox("soniox", "Soniox", "https://api.soniox.com/v1"),
    Speechmatics("speechmatics", "Speechmatics", "https://eu1.asr.api.speechmatics.com"),
    Cartesia("cartesia", "Cartesia", "https://api.cartesia.ai"),
    Gladia("gladia", "Gladia", "https://api.gladia.io"),
    Meta("meta", "Meta", "https://api.meta.ai/v1"),
    Smallest("smallest", "Smallest AI", "https://api.smallest.ai/waves/v1"),
    XAI("xai", "xAI", "https://api.x.ai/v1"),

    // Regional keys: each request's origin comes from the saved credential (see RegionalCredentials),
    // so these base URLs are only the providers' default hosts.
    Azure("azure", "Azure Speech", "https://eastus.api.cognitive.microsoft.com"),
    Alibaba("alibaba", "Alibaba Model Studio", "https://dashscope.aliyuncs.com"),
    StepFun("stepfun", "StepFun", "https://api.stepfun.ai/v1"),
    ;

    /** OpenAI and Groq take the OpenAI `/audio/transcriptions` form; the rest use [BatchTranscriber]. */
    val isOpenAICompatible: Boolean
        get() = this == OpenAI || this == Groq

    val credentialId: String
        get() = GeneratedCloudCatalog.providers.first { it.id == id }.credentialId

    companion object {
        internal fun forId(id: String): CloudProvider =
            entries.firstOrNull { it.id == id } ?: error("No Android transport for cloud provider '$id'")
    }
}

data class CloudModel(
    val catalogId: String,
    val displayName: String,
    val provider: CloudProvider,
    val apiName: String,
    /** The GPT transcription family takes `languages[]`; Whisper-compatible models take `language`. */
    val languageField: String,
    /** Whether the model takes a vocabulary glossary as its `prompt` form field. */
    val supportsPrompt: Boolean = false,
    /** The only languages the model accepts (Reson8, Smallest); null when the provider takes any. */
    val languageCodes: List<String>? = null,
    /**
     * The hint each primary language subtag sends (Gladia, Meta, xAI); a language outside it is sent as
     * automatic detection. Null when the provider takes any language code.
     */
    val languageHints: Map<String, String>? = null,
    /** Whether the provider takes only the canonical 16 kHz mono 16-bit WAV Android records (Meta, Inkling). */
    val requiresPCM16WAV: Boolean = false,
    /** Set for a streaming model: it transcribes while recording and cannot transcribe a file. */
    val live: LiveRoute? = null,
)

/** How a live model is reached, from SpeakCore's `ModelCatalog.liveTranscription`. */
data class LiveRoute(
    /** The PCM rate the provider expects; recording is 16 kHz, so other rates are resampled. */
    val sampleRate: Int,
    /** The wire name of the language hint, or empty when the model takes none. */
    val languageField: String,
    /** The wire name of the vocabulary hint (`keyterm`, `keyterms_prompt`, `prompt`), or empty. */
    val vocabularyField: String,
    /** How long a stop waits for the provider's last formatted text after the end-of-audio signal. */
    val finalizeBudgetMs: Long,
)

/** A cleanup route: a native provider's own API, or OpenRouter. */
data class CleanupModel(
    /** The identifier saved in settings, shared with the Mac (`native/<provider>/<model>` or an OpenRouter slug). */
    val selectionId: String,
    val displayName: String,
    val provider: CloudProvider,
    /** The model name the provider's `/chat/completions` endpoint expects. */
    val apiName: String,
    /** The provider name pickers sort by: the native provider, or the OpenRouter vendor. */
    val vendor: String,
) {
    val isOpenRouter: Boolean get() = provider == CloudProvider.OpenRouter
}

/**
 * Cloud models available on Android. Every value comes from [GeneratedCloudCatalog], which the build
 * writes from `assets/cloud_catalog.json` (generated from `Sources/SpeakCore` by
 * `CloudCatalogAndroidExport`, which also decides which models Android offers).
 */
object CloudCatalog {
    /** Models that transcribe a finished recording. */
    val batchTranscriptionModels: List<CloudModel> = GeneratedCloudCatalog.transcriptionModels.map {
        CloudModel(
            catalogId = it.catalogId,
            displayName = it.displayName,
            provider = CloudProvider.forId(it.providerId),
            apiName = it.apiName,
            languageField = it.languageField,
            supportsPrompt = it.supportsPrompt,
            languageCodes = it.languageCodes,
            languageHints = it.languageHints,
            requiresPCM16WAV = it.requiresPCM16WAV,
        )
    }

    /** Streaming models that show text while recording. */
    val liveTranscriptionModels: List<CloudModel> = GeneratedCloudCatalog.liveTranscriptionModels.map {
        CloudModel(
            catalogId = it.catalogId,
            displayName = it.displayName,
            provider = CloudProvider.forId(it.providerId),
            apiName = it.apiName,
            languageField = "",
            live = LiveRoute(
                sampleRate = it.sampleRate,
                languageField = it.languageField,
                vocabularyField = it.vocabularyField,
                finalizeBudgetMs = it.postStopFinalizeBudgetMs.toLong(),
            ),
        )
    }

    /** Every selectable cloud model: batch models first, then live ones. */
    val transcriptionModels: List<CloudModel> = batchTranscriptionModels + liveTranscriptionModels

    val defaultTranscriptionModel: CloudModel = batchTranscriptionModels.first()

    /** Matches `ModelCatalog.defaultPostProcessingModel` on the Mac (an OpenRouter route). */
    const val CLEANUP_MODEL = GeneratedCloudCatalog.CLEANUP_MODEL

    /** The provider the default cleanup model uses. */
    val cleanupProvider: CloudProvider = CloudProvider.forId(GeneratedCloudCatalog.CLEANUP_PROVIDER)

    /** SpeakCore's `ModelPickerGrouping.vendorNames`: the vendor an OpenRouter slug is filed under. */
    fun vendorName(slug: String): String = slug.substringBefore('/').let { prefix ->
        GeneratedCloudCatalog.openRouterVendorNames[prefix.lowercase(Locale.ROOT)] ?: prefix
    }

    /** Cleanup models in catalogue order: native provider routes, then OpenRouter slugs. */
    val cleanupModels: List<CleanupModel> = GeneratedCloudCatalog.cleanupModels.map {
        val provider = CloudProvider.forId(it.providerId)
        CleanupModel(
            selectionId = it.selectionId,
            displayName = it.displayName,
            provider = provider,
            apiName = it.apiName,
            vendor = if (provider == CloudProvider.OpenRouter) {
                vendorName(it.apiName)
            } else {
                provider.displayName
            },
        )
    }

    /**
     * A saved choice; a removed model's successor on the same route; otherwise the default.
     */
    fun cleanupModel(selectionId: String?): CleanupModel =
        findCleanupModel(selectionId) ?: cleanupModels.first { it.selectionId == CLEANUP_MODEL }

    /**
     * A bundled cleanup model (or a removed one's successor), or a saved discovered OpenAI model
     * (`openrouter/cleanup/openai/…`), which stays selected even when discovery is off or offline.
     */
    fun findCleanupModel(selectionId: String?): CleanupModel? {
        val current = selectionId?.let { GeneratedCloudCatalog.cleanupModelSuccessors[it] } ?: selectionId
        cleanupModels.firstOrNull { it.selectionId == current }?.let { return it }
        val slug = OpenRouterCleanupSelection.modelId(current) ?: return null
        return CleanupModel(
            selectionId = OpenRouterCleanupSelection.selectionId(slug),
            displayName = discoveredCleanupNames[slug]?.let { "$it (discovered)" } ?: "$slug (saved discovery)",
            provider = CloudProvider.OpenRouter,
            apiName = slug,
            vendor = vendorName(slug),
        )
    }

    fun transcriptionModel(catalogId: String?): CloudModel = findTranscriptionModel(catalogId) ?: defaultTranscriptionModel

    /**
     * A bundled transcription model, or a saved OpenRouter speech-to-text model
     * (`openrouter/transcription/…`), which is sent to OpenRouter's dedicated endpoint.
     */
    fun findTranscriptionModel(catalogId: String?): CloudModel? {
        transcriptionModels.firstOrNull { it.catalogId == catalogId }?.let { return it }
        val slug = OpenRouterTranscriptionSelection.modelId(catalogId) ?: return null
        return CloudModel(
            catalogId = OpenRouterTranscriptionSelection.selectionId(slug),
            displayName = discoveredTranscriptionNames[slug] ?: slug,
            provider = CloudProvider.OpenRouter,
            apiName = slug,
            languageField = "language",
        )
    }

    /** Whether a transcription model goes through OpenRouter, so it is labelled "OpenRouter › name". */
    fun isOpenRouterTranscription(model: CloudModel): Boolean = model.provider == CloudProvider.OpenRouter

    @Volatile
    private var discoveredCleanupNames: Map<String, String> = emptyMap()

    @Volatile
    private var discoveredTranscriptionNames: Map<String, String> = emptyMap()

    /** Discovery's latest names, so a saved discovered model shows its name rather than its slug. */
    fun rememberDiscoveredNames(cleanup: Map<String, String>, transcription: Map<String, String>) {
        discoveredCleanupNames = cleanup
        discoveredTranscriptionNames = transcription
    }

    /** Providers whose keys the app can use, in settings order. */
    val providers: List<CloudProvider> = GeneratedCloudCatalog.providers.map { CloudProvider.forId(it.id) }
}
