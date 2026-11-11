package com.justspeaktoit.android.cloud

/** A provider row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class CloudProviderSpec(val id: String, val credentialId: String)

/** A transcription model row of `assets/cloud_catalog.json`, as written into [GeneratedCloudCatalog]. */
internal data class CloudModelSpec(
    val catalogId: String,
    val displayName: String,
    val providerId: String,
    val apiName: String,
    val languageField: String,
)

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
    ;

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
)

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
        )
    }

    val defaultTranscriptionModel: CloudModel = transcriptionModels.first()

    /** Matches `ModelCatalog.defaultPostProcessingModel` on the Mac. */
    const val CLEANUP_MODEL = GeneratedCloudCatalog.CLEANUP_MODEL

    /** The provider cleanup requests go to. */
    val cleanupProvider: CloudProvider = CloudProvider.forId(GeneratedCloudCatalog.CLEANUP_PROVIDER)

    fun transcriptionModel(catalogId: String?): CloudModel =
        transcriptionModels.firstOrNull { it.catalogId == catalogId } ?: defaultTranscriptionModel

    /** Providers whose keys the app can use, in settings order. */
    val providers: List<CloudProvider> = GeneratedCloudCatalog.providers.map { CloudProvider.forId(it.id) }
}
