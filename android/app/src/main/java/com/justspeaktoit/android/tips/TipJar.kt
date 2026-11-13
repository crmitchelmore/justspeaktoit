package com.justspeaktoit.android.tips

import org.json.JSONObject

/** One tip tier from `assets/tip_catalog.json`, which SpeakCore's `TipCatalogAndroidExport` writes. */
data class TipTier(val productId: String, val emoji: String, val displayName: String, val summary: String)

object TipCatalogParser {
    const val ASSET = "tip_catalog.json"
    private const val VERSION = 1

    fun parse(json: String): List<TipTier> {
        val root = JSONObject(json)
        require(root.getInt("version") == VERSION) { "Unsupported tip catalogue version" }
        val products = root.getJSONArray("products")
        return List(products.length()) { index ->
            val product = products.getJSONObject(index)
            TipTier(
                productId = product.getString("id"),
                emoji = product.getString("emoji"),
                displayName = product.getString("displayName"),
                summary = product.getString("summary"),
            )
        }
    }
}

/** What Google Play returned for one product. */
data class StoreProduct(val productId: String, val name: String, val formattedPrice: String, val priceMicros: Long)

/** A tip the user can buy now. */
data class TipOffer(val productId: String, val emoji: String, val name: String, val price: String)

object TipOffers {
    /**
     * Only catalogue tiers Play actually sells are offered, cheapest first like the Mac tip jar. Play's localised
     * name wins; the catalogue name covers a product with no name.
     */
    fun merge(tiers: List<TipTier>, products: List<StoreProduct>): List<TipOffer> {
        val byId = tiers.associateBy { it.productId }
        return products
            .filter { it.productId in byId }
            .distinctBy { it.productId }
            .sortedBy { it.priceMicros }
            .map { product ->
                val tier = byId.getValue(product.productId)
                TipOffer(
                    productId = product.productId,
                    emoji = tier.emoji,
                    name = product.name.ifBlank { tier.displayName },
                    price = product.formattedPrice,
                )
            }
    }
}

enum class TipJarStatus {
    Loading,

    /** Play Billing isn't available: a sideloaded or debug build, no Play Store, or no products. */
    Unavailable,
    Ready,
}

enum class TipMessage { Thanks, Pending, Failed }

data class TipJarUiState(
    val status: TipJarStatus = TipJarStatus.Loading,
    val offers: List<TipOffer> = emptyList(),
    val purchasingProductId: String? = null,
    val message: TipMessage? = null,
)

/** How a purchase attempt ended. */
enum class TipOutcome { Purchased, Pending, Cancelled, Failed }

object TipJarReducer {
    fun loaded(state: TipJarUiState, offers: List<TipOffer>): TipJarUiState =
        state.copy(status = if (offers.isEmpty()) TipJarStatus.Unavailable else TipJarStatus.Ready, offers = offers)

    fun unavailable(state: TipJarUiState): TipJarUiState =
        state.copy(status = TipJarStatus.Unavailable, offers = emptyList(), purchasingProductId = null)

    /** Ignored while another purchase is in progress or for a product that isn't offered. */
    fun purchaseStarted(state: TipJarUiState, productId: String): TipJarUiState {
        if (state.purchasingProductId != null || state.offers.none { it.productId == productId }) return state
        return state.copy(purchasingProductId = productId, message = null)
    }

    fun finished(state: TipJarUiState, outcome: TipOutcome): TipJarUiState = state.copy(
        purchasingProductId = null,
        message = when (outcome) {
            TipOutcome.Purchased -> TipMessage.Thanks
            TipOutcome.Pending -> TipMessage.Pending
            TipOutcome.Failed -> TipMessage.Failed
            TipOutcome.Cancelled -> null
        },
    )
}
