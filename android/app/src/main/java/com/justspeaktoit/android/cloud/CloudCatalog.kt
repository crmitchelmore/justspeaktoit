package com.justspeaktoit.android.cloud

/**
 * Cloud providers available on Android. Identifiers mirror the Mac app (`Sources/SpeakCore`):
 * credential IDs follow `ProviderCredentialCatalogue.apiKeyIdentifier`, and model IDs come from
 * `ModelCatalog`. `CloudCatalogParityTest` fails if either drifts.
 */
enum class CloudProvider(val id: String, val displayName: String, val baseUrl: String) {
    OpenAI("openai", "OpenAI", "https://api.openai.com/v1"),
    Groq("groq", "Groq", "https://api.groq.com/openai/v1"),
    OpenRouter("openrouter", "OpenRouter", "https://openrouter.ai/api/v1"),
    Anthropic("anthropic", "Anthropic", "https://api.anthropic.com/v1"),
    Google("google", "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
    Mistral("mistral", "Mistral", "https://api.mistral.ai/v1"),
    ;

    val credentialId: String get() = "$id.apiKey"
}

data class CloudModel(
    val catalogId: String,
    val displayName: String,
    val provider: CloudProvider,
    val apiName: String,
    /** The GPT transcription family takes `languages[]`; Whisper-compatible models take `language`. */
    val languageField: String,
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

object CloudCatalog {
    val transcriptionModels: List<CloudModel> = listOf(
        CloudModel(
            catalogId = "openai/gpt-transcribe",
            displayName = "GPT Transcribe (OpenAI)",
            provider = CloudProvider.OpenAI,
            apiName = "gpt-transcribe",
            languageField = "languages[]",
        ),
        CloudModel(
            catalogId = "groq/whisper-large-v3-turbo",
            displayName = "Whisper Large v3 Turbo (Groq)",
            provider = CloudProvider.Groq,
            apiName = "whisper-large-v3-turbo",
            languageField = "language",
        ),
    )

    val defaultTranscriptionModel: CloudModel = transcriptionModels.first()

    /** Matches `ModelCatalog.defaultPostProcessingModel` on the Mac (an OpenRouter route). */
    const val CLEANUP_MODEL = "openai/gpt-5-mini"

    // Declared before cleanupModels: object properties initialise in order.
    /** Matches `ModelPickerGrouping.vendorNames` on the Mac. */
    private val VENDOR_NAMES = mapOf(
        "anthropic" to "Anthropic", "google" to "Google", "meta-llama" to "Meta Llama",
        "mistralai" to "Mistral", "openai" to "OpenAI", "qwen" to "Qwen",
    )

    /**
     * Cleanup models. Native routes mirror `NativeTextModels.postProcessing` (`native/<provider>/<model>`);
     * OpenRouter routes mirror the unprefixed entries of `ModelCatalog.postProcessing`. `CloudParityTest`
     * fails if either drifts.
     */
    val cleanupModels: List<CleanupModel> = listOf(
        native(CloudProvider.Anthropic, "claude-haiku-4-5", "Claude Haiku 4.5"),
        native(CloudProvider.Anthropic, "claude-sonnet-4-6", "Claude Sonnet 4.6"),
        native(CloudProvider.OpenAI, "gpt-6-luna", "GPT-6 Luna"),
        native(CloudProvider.OpenAI, "gpt-5-mini", "GPT-5 Mini"),
        native(CloudProvider.OpenAI, "gpt-5.4-mini", "GPT-5.4 Mini"),
        native(CloudProvider.OpenAI, "gpt-6.1-sol", "GPT-6.1 Sol"),
        native(CloudProvider.Google, "gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
        native(CloudProvider.Google, "gemini-2.5-flash", "Gemini 2.5 Flash"),
        native(CloudProvider.Groq, "openai/gpt-oss-120b", "GPT-OSS 120B"),
        native(CloudProvider.Groq, "llama-3.1-8b-instant", "Llama 3.1 8B Instant"),
        native(CloudProvider.Mistral, "mistral-small-latest", "Mistral Small"),
        openRouter("openai/gpt-6-luna", "GPT-6 Luna"),
        openRouter("openai/gpt-6.1-sol", "GPT-6.1 Sol"),
        openRouter("openai/gpt-6-astra", "GPT-6 Astra"),
        openRouter("openai/gpt-5.4-nano", "GPT-5.4 Nano"),
        openRouter("openai/gpt-5-mini", "GPT-5 Mini"),
        openRouter("google/gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
        openRouter("qwen/qwen3.6-flash", "Qwen3.6 Flash"),
        openRouter("mistralai/mistral-small-2603", "Mistral Small 4"),
        openRouter("google/gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite"),
        openRouter("qwen/qwen3.6-35b-a3b", "Qwen3.6 35B A3B"),
        openRouter("meta-llama/llama-4-scout", "Llama 4 Scout"),
        openRouter("anthropic/claude-haiku-4.5", "Claude Haiku 4.5"),
        openRouter("openai/gpt-5.6-luna", "GPT-5.6 Luna"),
        openRouter("openai/gpt-5.4-mini", "GPT-5.4 Mini"),
        openRouter("google/gemini-2.5-flash", "Gemini 2.5 Flash"),
        openRouter("openai/gpt-5.5", "GPT-5.5"),
        openRouter("openai/gpt-5.6-terra", "GPT-5.6 Terra"),
        openRouter("openai/gpt-5.6-sol", "GPT-5.6 Sol"),
        openRouter("anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6"),
        openRouter("openai/gpt-5.4", "GPT-5.4"),
    )

    /** A saved choice, or the default when it is missing or no longer offered. */
    fun cleanupModel(selectionId: String?): CleanupModel =
        cleanupModels.firstOrNull { it.selectionId == selectionId }
            ?: cleanupModels.first { it.selectionId == CLEANUP_MODEL }

    private fun native(provider: CloudProvider, apiName: String, displayName: String) = CleanupModel(
        selectionId = "native/${provider.id}/$apiName",
        displayName = displayName,
        provider = provider,
        apiName = apiName,
        vendor = provider.displayName,
    )

    private fun openRouter(slug: String, displayName: String) = CleanupModel(
        selectionId = slug,
        displayName = displayName,
        provider = CloudProvider.OpenRouter,
        apiName = slug,
        vendor = VENDOR_NAMES[slug.substringBefore('/')] ?: slug.substringBefore('/'),
    )


    fun transcriptionModel(catalogId: String?): CloudModel =
        transcriptionModels.firstOrNull { it.catalogId == catalogId } ?: defaultTranscriptionModel

    /** Providers whose keys the app can use, in settings order. */
    val providers: List<CloudProvider> = CloudProvider.entries
}
