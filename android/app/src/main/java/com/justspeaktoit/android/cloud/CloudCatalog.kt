package com.justspeaktoit.android.cloud

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
    /** The only languages the model accepts (Reson8); null when the provider takes any. */
    val languageCodes: List<String>? = null,
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
    val transcriptionModels: List<CloudModel> = GeneratedCloudCatalog.transcriptionModels.map {
        CloudModel(
            catalogId = it.catalogId,
            displayName = it.displayName,
            provider = CloudProvider.forId(it.providerId),
            apiName = it.apiName,
            languageField = it.languageField,
            supportsPrompt = it.supportsPrompt,
            languageCodes = it.languageCodes,
        )
    }

    val defaultTranscriptionModel: CloudModel = transcriptionModels.first()

    /** Matches `ModelCatalog.defaultPostProcessingModel` on the Mac (an OpenRouter route). */
    const val CLEANUP_MODEL = GeneratedCloudCatalog.CLEANUP_MODEL

    /** The provider the default cleanup model uses. */
    val cleanupProvider: CloudProvider = CloudProvider.forId(GeneratedCloudCatalog.CLEANUP_PROVIDER)

    // Declared before cleanupModels: object properties initialise in order.
    /** Matches `ModelPickerGrouping.vendorNames` on the Mac. */
    private val VENDOR_NAMES = mapOf(
        "anthropic" to "Anthropic", "google" to "Google", "meta-llama" to "Meta Llama",
        "mistralai" to "Mistral", "openai" to "OpenAI", "qwen" to "Qwen",
    )

    /** Cleanup models in catalogue order: native provider routes, then OpenRouter slugs. */
    val cleanupModels: List<CleanupModel> = GeneratedCloudCatalog.cleanupModels.map {
        val provider = CloudProvider.forId(it.providerId)
        CleanupModel(
            selectionId = it.selectionId,
            displayName = it.displayName,
            provider = provider,
            apiName = it.apiName,
            vendor = if (provider == CloudProvider.OpenRouter) {
                it.apiName.substringBefore('/').let { prefix -> VENDOR_NAMES[prefix] ?: prefix }
            } else {
                provider.displayName
            },
        )
    }

    /**
     * A saved choice; a removed model's successor on the same route; otherwise the default.
     */
    fun cleanupModel(selectionId: String?): CleanupModel {
        val current = selectionId?.let { GeneratedCloudCatalog.cleanupModelSuccessors[it] } ?: selectionId
        return cleanupModels.firstOrNull { it.selectionId == current }
            ?: cleanupModels.first { it.selectionId == CLEANUP_MODEL }
    }

    fun transcriptionModel(catalogId: String?): CloudModel =
        transcriptionModels.firstOrNull { it.catalogId == catalogId } ?: defaultTranscriptionModel

    /** Providers whose keys the app can use, in settings order. */
    val providers: List<CloudProvider> = GeneratedCloudCatalog.providers.map { CloudProvider.forId(it.id) }
}
