package com.justspeaktoit.android.cloud

/**
 * Cloud providers available on Android. Identifiers, credential IDs and models are a typed mirror of
 * `assets/cloud_catalog.json`, which `CloudCatalogAndroidExport` generates from `Sources/SpeakCore`
 * (including which models Android offers); `CloudCatalogParityTest` fails on any difference. They
 * stay compile-time constants so the catalogue costs nothing at startup. Base URLs are Android's
 * transport detail.
 */
enum class CloudProvider(val id: String, val displayName: String, val baseUrl: String) {
    OpenAI("openai", "OpenAI", "https://api.openai.com/v1"),
    Groq("groq", "Groq", "https://api.groq.com/openai/v1"),
    OpenRouter("openrouter", "OpenRouter", "https://openrouter.ai/api/v1"),
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

    /** Matches `ModelCatalog.defaultPostProcessingModel` on the Mac. */
    const val CLEANUP_MODEL = "openai/gpt-5-mini"

    fun transcriptionModel(catalogId: String?): CloudModel =
        transcriptionModels.firstOrNull { it.catalogId == catalogId } ?: defaultTranscriptionModel

    /** Providers whose keys the app can use, in settings order. */
    val providers: List<CloudProvider> = CloudProvider.entries
}
