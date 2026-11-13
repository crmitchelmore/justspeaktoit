package com.justspeaktoit.android.tips

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.junit.Assert.assertEquals
import org.junit.Test

class TipJarTest {
    private val tiers = TipCatalogParser.parse(SettingsSearchAsset.locate("app/src/main/assets/tip_catalog.json").readText())

    @Test
    fun testCatalogue_listsTheAppleTipProducts() {
        assertEquals(
            listOf("com.justspeaktoit.tip.small", "com.justspeaktoit.tip.medium", "com.justspeaktoit.tip.large"),
            tiers.map { it.productId },
        )
    }

    @Test
    fun testMerge_offersOnlySoldTiersCheapestFirstWithFallbackName() {
        val offers = TipOffers.merge(
            tiers,
            listOf(
                StoreProduct("com.justspeaktoit.tip.large", "Big tip", "£9.99", 9_990_000),
                StoreProduct("com.justspeaktoit.tip.small", "", "£1.99", 1_990_000),
                StoreProduct("com.example.unrelated", "Other", "£0.99", 990_000),
            ),
        )

        assertEquals(listOf("com.justspeaktoit.tip.small", "com.justspeaktoit.tip.large"), offers.map { it.productId })
        assertEquals("Buy me a coffee", offers.first().name)
        assertEquals("☕", offers.first().emoji)
        assertEquals("Big tip", offers.last().name)
    }

    @Test
    fun testReducer_purchaseLifecycle() {
        val offers = TipOffers.merge(tiers, listOf(StoreProduct(tiers[0].productId, "Coffee", "£1.99", 1)))
        val ready = TipJarReducer.loaded(TipJarUiState(), offers)
        assertEquals(TipJarStatus.Ready, ready.status)

        val buying = TipJarReducer.purchaseStarted(ready, tiers[0].productId)
        assertEquals(tiers[0].productId, buying.purchasingProductId)
        assertEquals(buying, TipJarReducer.purchaseStarted(buying, tiers[0].productId))
        assertEquals(ready, TipJarReducer.purchaseStarted(ready, "com.example.unrelated"))

        assertEquals(TipMessage.Thanks, TipJarReducer.finished(buying, TipOutcome.Purchased).message)
        assertEquals(TipMessage.Pending, TipJarReducer.finished(buying, TipOutcome.Pending).message)
        assertEquals(TipMessage.Unconfirmed, TipJarReducer.finished(buying, TipOutcome.Unconfirmed).message)
        assertEquals(null, TipJarReducer.finished(buying, TipOutcome.Cancelled).message)
        assertEquals(null, TipJarReducer.finished(buying, TipOutcome.Failed).purchasingProductId)
    }

    @Test
    fun testConsumptions_keepAFailedConsumeForRetry() {
        val consumptions = TipConsumptions()
        consumptions.add(listOf("a", "b"))
        consumptions.finished("a", consumed = true)
        consumptions.finished("b", consumed = false)
        assertEquals(listOf("b"), consumptions.pending())

        consumptions.add(listOf("c"))
        assertEquals(listOf("b", "c"), consumptions.pending())
        consumptions.finished("b", consumed = true)
        consumptions.finished("c", consumed = true)
        assertEquals(emptyList<String>(), consumptions.pending())
    }

    @Test
    fun testNoProducts_isUnavailable() {
        assertEquals(TipJarStatus.Unavailable, TipJarReducer.loaded(TipJarUiState(), emptyList()).status)
    }
}
