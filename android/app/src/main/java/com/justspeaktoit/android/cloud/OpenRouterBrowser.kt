package com.justspeaktoit.android.cloud

import java.net.URLEncoder
import java.util.Locale

/**
 * A row of `cloud_catalog.json`'s `openRouterBrowser.cleanupModels` or `transcriptionModels`, as written into
 * [GeneratedCloudCatalog]. SpeakCore's `OpenRouterModelBrowserCatalog.cleanupItems` builds it.
 */
internal data class OpenRouterBrowserModelSpec(
    val selectionId: String,
    val slug: String,
    val name: String,
    val provider: String,
    val subtitle: String,
    val summary: String,
    val speed: String,
    val pricing: String?,
    val contextLength: Int?,
    val strengths: List<String>,
    val hasZeroPrices: Boolean,
    val searchText: List<String>,
    val modelPageUrl: String?,
)

/** One OpenRouter model in the browser, with everything its details page shows. */
data class OpenRouterBrowserItem(
    /** The identifier saved when the model is chosen (cleanup selection or transcription catalogue ID). */
    val selectionId: String,
    /** The model slug sent to OpenRouter, for example `openai/gpt-6-luna`. */
    val slug: String,
    val name: String,
    /** The vendor the model is filed under ("OpenAI"), never OpenRouter itself. */
    val provider: String,
    /** The row's secondary line: the slug and listed prices, or where the model came from. */
    val subtitle: String,
    val summary: String,
    val speed: String,
    /** Input and output rates per million tokens, when listed. */
    val pricing: String?,
    val contextLength: Int?,
    val strengths: List<String>,
    /** Only listed zero prices count; a missing price is unknown, not free. */
    val hasZeroPrices: Boolean,
    val searchText: List<String>,
    val modelPageUrl: String?,
    /** Found by live discovery rather than bundled with the app. */
    val discovered: Boolean = false,
    /** A discovered cleanup model that has not been tested for cleanup. */
    val unqualified: Boolean = false,
    /** A discovered audio model's own price keys and values; units vary by model. */
    val listedPrices: Map<String, String> = emptyMap(),
)

/**
 * SpeakCore's `OpenRouterBrowserFilter`: the query is trimmed and matched case-insensitively against
 * each item's search text, the provider must match exactly, and Zero listed prices keeps only items
 * whose listed prices are all zero. `Tests/Fixtures/openrouter-browser/filter-cases.json` holds the
 * cases both platforms test.
 */
data class OpenRouterBrowserFilter(
    val query: String = "",
    /** The vendor name to match exactly; empty means every provider. */
    val provider: String = "",
    val freeOnly: Boolean = false,
) {
    fun matches(searchText: List<String>, provider: String, hasZeroPrices: Boolean): Boolean {
        if (this.provider.isNotEmpty() && provider != this.provider) return false
        if (freeOnly && !hasZeroPrices) return false
        val search = query.trim()
        return search.isEmpty() || searchText.any { it.contains(search, ignoreCase = true) }
    }
}

/**
 * The **Browse OpenRouter models…** browser: native cleanup models stay in the main picker, and
 * this lists OpenRouter models with search, provider and price filters and a details page before a
 * model is chosen. Rows, order and copy come from SpeakCore through [GeneratedCloudCatalog].
 */
object OpenRouterBrowser {
    const val BROWSE_TITLE = GeneratedCloudCatalog.OPENROUTER_BROWSE_TITLE
    const val CLEANUP_TITLE = GeneratedCloudCatalog.OPENROUTER_CLEANUP_TITLE
    const val CLEANUP_INTRO = GeneratedCloudCatalog.OPENROUTER_CLEANUP_INTRO
    const val SEARCH_PLACEHOLDER = GeneratedCloudCatalog.OPENROUTER_SEARCH_PLACEHOLDER
    const val ALL_PROVIDERS = GeneratedCloudCatalog.OPENROUTER_ALL_PROVIDERS
    const val ZERO_PRICES = GeneratedCloudCatalog.OPENROUTER_ZERO_PRICES
    const val PRICING_CAVEAT = GeneratedCloudCatalog.OPENROUTER_PRICING_CAVEAT
    const val PRICING_UNLISTED = GeneratedCloudCatalog.OPENROUTER_PRICING_UNLISTED
    const val CLEANUP_USE = GeneratedCloudCatalog.OPENROUTER_CLEANUP_USE
    const val CLEANUP_SELECTED = GeneratedCloudCatalog.OPENROUTER_CLEANUP_SELECTED
    const val CLEANUP_ROUTE_NOTE = GeneratedCloudCatalog.OPENROUTER_CLEANUP_ROUTE_NOTE

    const val TRANSCRIPTION_TITLE = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_TITLE
    const val TRANSCRIPTION_INTRO = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_INTRO
    const val TRANSCRIPTION_USE = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_USE
    const val TRANSCRIPTION_SELECTED = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_SELECTED
    const val TRANSCRIPTION_ROUTE_NOTE = GeneratedCloudCatalog.OPENROUTER_TRANSCRIPTION_ROUTE_NOTE
    const val STREAMING_NOTE = GeneratedCloudCatalog.OPENROUTER_STREAMING_NOTE
    const val EMPTY_RESULTS = GeneratedCloudCatalog.OPENROUTER_EMPTY_RESULTS
    const val UNQUALIFIED_WARNING = GeneratedCloudCatalog.OPENROUTER_UNQUALIFIED_WARNING
    const val DISCOVERY_SETTING_TITLE = GeneratedCloudCatalog.OPENROUTER_DISCOVERY_SETTING_TITLE
    const val DISCOVERY_NOTE = GeneratedCloudCatalog.OPENROUTER_DISCOVERY_NOTE
    const val LISTED_PRICES_NOTE = "These are the provider's listed values. Units vary by model; check OpenRouter before use."

    private const val DISCOVERED_SUMMARY =
        "OpenAI via OpenRouter. Unqualified for cleanup; base rates may vary by context/provider."
    private const val RETAINED_SUMMARY = "Your saved OpenRouter choice. Availability and pricing may have changed."
    private const val MODEL_PAGE = "https://openrouter.ai/"

    /** "OpenRouter › name", as the Mac, iPhone and desktop pickers label an OpenRouter route. */
    fun selectionLabel(name: String): String =
        CloudProvider.OpenRouter.displayName + CleanupModelPicker.OPENROUTER_SEPARATOR + name

    /** The bundled OpenRouter cleanup models, in SpeakCore's vendor-then-name order. */
    val cleanupItems: List<OpenRouterBrowserItem> by lazy {
        cleanupItems(GeneratedCloudCatalog.openRouterCleanupModels, CloudCatalog.cleanupModels)
    }

    internal fun cleanupItems(
        specs: List<OpenRouterBrowserModelSpec>,
        models: List<CleanupModel>,
    ): List<OpenRouterBrowserItem> = specs.mapNotNull { spec ->
        models.firstOrNull { it.isOpenRouter && it.selectionId == spec.selectionId }?.let { item(spec) }
    }

    /**
     * SpeakCore's `CleanupModelDiscoveryStore.options` through `cleanupItems(options:)`: the bundled
     * models, discovered OpenAI models while discovery is on (bundled and retired IDs excluded), and a
     * saved discovery that is no longer listed, in vendor-then-name order.
     */
    fun cleanupItems(
        discovered: List<DiscoveredCleanupModel>,
        discoveryEnabled: Boolean,
        selected: String?,
        bundled: List<OpenRouterBrowserItem> = cleanupItems,
    ): List<OpenRouterBrowserItem> {
        val bundledSlugs = CloudCatalog.cleanupModels.map { it.selectionId }.toSet() +
            GeneratedCloudCatalog.cleanupModelSuccessors.keys
        val found = if (discoveryEnabled) {
            discovered.filter { it.isValid && it.id !in bundledSlugs }.distinctBy { it.id }.map(::discoveredItem)
        } else {
            emptyList()
        }
        val retained = OpenRouterCleanupSelection.modelId(selected)
            ?.takeIf { slug -> found.none { it.slug == slug } }
            ?.let { slug -> retainedItem(slug) }
        return (bundled + found + listOfNotNull(retained)).sortedWith { a, b ->
            CleanupModelPicker.compareNatural(a.provider, b.provider).takeIf { it != 0 }
                ?: CleanupModelPicker.compareNatural(a.name, b.name)
        }
    }

    /** The bundled OpenRouter batch transcription models, in SpeakCore's order. */
    val transcriptionItems: List<OpenRouterBrowserItem> by lazy {
        transcriptionItems(GeneratedCloudCatalog.openRouterTranscriptionModels, CloudCatalog.transcriptionModels)
    }

    internal fun transcriptionItems(
        specs: List<OpenRouterBrowserModelSpec>,
        models: List<CloudModel>,
    ): List<OpenRouterBrowserItem> = specs.mapNotNull { spec ->
        models.firstOrNull { it.provider == CloudProvider.OpenRouter && it.catalogId == spec.selectionId }
            ?.let { item(spec) }
    }

    /**
     * SpeakCore's `OpenRouterModelBrowserCatalog.transcriptionItems`: bundled models first, then live
     * speech-to-text models by name. A discovered model that duplicates a listed selection is dropped.
     */
    fun transcriptionItems(
        discovered: List<OpenRouterAudioModel>,
        bundled: List<OpenRouterBrowserItem> = transcriptionItems,
    ): List<OpenRouterBrowserItem> {
        val seen = bundled.map { it.selectionId.lowercase(Locale.ROOT) }.toMutableSet()
        val found = discovered
            .filter { it.supportsTranscription && seen.add(it.transcriptionSelectionId.lowercase(Locale.ROOT)) }
            .sortedWith { a, b -> CleanupModelPicker.compareNatural(a.name, b.name).takeIf { it != 0 } ?: a.id.compareTo(b.id) }
            .map(::audioItem)
        return bundled + found
    }

    private fun item(spec: OpenRouterBrowserModelSpec) = OpenRouterBrowserItem(
        selectionId = spec.selectionId,
        slug = spec.slug,
        name = spec.name,
        provider = spec.provider,
        subtitle = spec.subtitle,
        summary = spec.summary,
        speed = spec.speed,
        pricing = spec.pricing,
        contextLength = spec.contextLength,
        strengths = spec.strengths,
        hasZeroPrices = spec.hasZeroPrices,
        searchText = spec.searchText,
        modelPageUrl = spec.modelPageUrl,
    )

    private fun discoveredItem(model: DiscoveredCleanupModel): OpenRouterBrowserItem {
        val name = model.name + " (discovered)"
        val pricing = OpenRouterDiscovery.pricingDisplay(model.inputPrice, model.outputPrice)
        val provider = CloudCatalog.vendorName(model.id)
        return OpenRouterBrowserItem(
            selectionId = model.selectionId,
            slug = model.id,
            name = name,
            provider = provider,
            subtitle = listOfNotNull(model.id, pricing).joinToString(" · "),
            summary = DISCOVERED_SUMMARY,
            speed = "",
            pricing = pricing,
            contextLength = model.contextLength,
            strengths = emptyList(),
            hasZeroPrices = model.inputPrice == 0.0 && model.outputPrice == 0.0,
            searchText = listOf(name, model.selectionId, DISCOVERED_SUMMARY, provider),
            modelPageUrl = MODEL_PAGE + model.id,
            discovered = true,
            unqualified = true,
        )
    }

    private fun retainedItem(slug: String): OpenRouterBrowserItem {
        val name = "$slug (saved discovery)"
        val selectionId = OpenRouterCleanupSelection.selectionId(slug)
        val provider = CloudCatalog.vendorName(slug)
        return OpenRouterBrowserItem(
            selectionId = selectionId,
            slug = slug,
            name = name,
            provider = provider,
            subtitle = slug,
            summary = RETAINED_SUMMARY,
            speed = "",
            pricing = null,
            contextLength = null,
            strengths = emptyList(),
            hasZeroPrices = false,
            searchText = listOf(name, selectionId, RETAINED_SUMMARY, provider),
            modelPageUrl = MODEL_PAGE + slug,
            discovered = true,
            unqualified = true,
        )
    }

    private fun audioItem(model: OpenRouterAudioModel): OpenRouterBrowserItem {
        val provider = CloudCatalog.vendorName(model.id)
        val name = uiText(model.name)
        return OpenRouterBrowserItem(
            selectionId = model.transcriptionSelectionId,
            slug = model.id,
            name = name,
            provider = provider,
            subtitle = "Discovered · ${model.id}",
            summary = uiText(model.description),
            speed = "",
            pricing = null,
            contextLength = model.contextLength,
            strengths = emptyList(),
            hasZeroPrices = OpenRouterDiscovery.hasZeroPrices(model.pricing),
            searchText = listOf(model.id, model.name, model.description, provider),
            modelPageUrl = modelPageUrl(model.id),
            discovered = true,
            listedPrices = model.pricing.mapKeys { uiText(it.key) }.mapValues { uiText(it.value) },
        )
    }

    /** SpeakCore's `OpenRouterCatalogOptions.modelPageURL`: only a plain `vendor/model` slug links out. */
    internal fun modelPageUrl(slug: String): String? {
        val parts = slug.split('/')
        if (parts.size != 2 || parts.any { it.isEmpty() }) return null
        if (slug.any { it.isWhitespace() || Character.isISOControl(it) }) return null
        return MODEL_PAGE + parts.joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
    }

    /** Provider metadata is untrusted UI text: bounded, with control characters replaced. */
    private fun uiText(value: String): String =
        value.take(1024).map { if (Character.isISOControl(it)) ' ' else it }.joinToString("")

    fun filtered(items: List<OpenRouterBrowserItem>, filter: OpenRouterBrowserFilter): List<OpenRouterBrowserItem> =
        items.filter { filter.matches(it.searchText, it.provider, it.hasZeroPrices) }

    /** The provider filter's choices, alphabetical and without duplicates. */
    fun providers(items: List<OpenRouterBrowserItem>): List<String> =
        items.map { it.provider }.distinct().sortedWith { a, b -> CleanupModelPicker.compareNatural(a, b) }
}
