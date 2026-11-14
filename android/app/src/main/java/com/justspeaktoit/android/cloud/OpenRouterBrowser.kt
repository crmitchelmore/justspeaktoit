package com.justspeaktoit.android.cloud

/**
 * A row of `cloud_catalog.json`'s `openRouterBrowser.cleanupModels`, as written into
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
    val model: CleanupModel,
    /** The model slug sent to OpenRouter, for example `openai/gpt-6-luna`. */
    val slug: String,
    val name: String,
    /** The vendor the model is filed under ("OpenAI"), never OpenRouter itself. */
    val provider: String,
    /** The row's secondary line: the slug and listed prices. */
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

    /** The bundled OpenRouter cleanup models, in SpeakCore's vendor-then-name order. */
    val cleanupItems: List<OpenRouterBrowserItem> by lazy {
        cleanupItems(GeneratedCloudCatalog.openRouterCleanupModels, CloudCatalog.cleanupModels)
    }

    internal fun cleanupItems(
        specs: List<OpenRouterBrowserModelSpec>,
        models: List<CleanupModel>,
    ): List<OpenRouterBrowserItem> = specs.mapNotNull { spec ->
        models.firstOrNull { it.isOpenRouter && it.selectionId == spec.selectionId }?.let { model ->
            OpenRouterBrowserItem(
                model = model,
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
        }
    }

    fun filtered(items: List<OpenRouterBrowserItem>, filter: OpenRouterBrowserFilter): List<OpenRouterBrowserItem> =
        items.filter { filter.matches(it.searchText, it.provider, it.hasZeroPrices) }

    /** The provider filter's choices, alphabetical and without duplicates. */
    fun providers(items: List<OpenRouterBrowserItem>): List<String> =
        items.map { it.provider }.distinct().sortedWith { a, b -> CleanupModelPicker.compareNatural(a, b) }
}
