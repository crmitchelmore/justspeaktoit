package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The OpenRouter browser against SpeakCore: rows and copy from `assets/cloud_catalog.json`, and the
 * filter against `Tests/Fixtures/openrouter-browser/filter-cases.json`, which the Swift tests share.
 */
class OpenRouterBrowserTest {
    private val asset = JSONObject(SettingsSearchAsset.locate("app/src/main/assets/cloud_catalog.json").readText())
        .getJSONObject("openRouterBrowser")

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    @Test
    fun testFilter_matchesTheSharedFixtureCases() {
        val fixture = JSONObject(RepoSources.fixture("openrouter-browser/filter-cases.json"))
        val items = fixture.getJSONArray("items").let { array -> (0 until array.length()).map(array::getJSONObject) }
        val cases = fixture.getJSONArray("cases")
        assertTrue(cases.length() > 0)
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val filter = OpenRouterBrowserFilter(
                query = case.getString("query"),
                provider = case.getString("provider"),
                freeOnly = case.getBoolean("freeOnly"),
            )
            val matched = items.filter {
                filter.matches(
                    it.getJSONArray("searchText").strings(),
                    it.getString("provider"),
                    it.getBoolean("hasZeroPrices"),
                )
            }.map { it.getString("id") }
            assertEquals("case $index: $case", case.getJSONArray("expected").strings(), matched)
        }
    }

    @Test
    fun testCleanupItems_areEveryOpenRouterCleanupModelInSpeakCoreOrder() {
        val items = OpenRouterBrowser.cleanupItems
        val exported = asset.getJSONArray("cleanupModels")
        val ids = items.map { it.model.selectionId }
        assertEquals((0 until exported.length()).map { exported.getJSONObject(it).getString("selectionId") }, ids)
        assertEquals(CleanupModelPicker.openRouter().map { it.selectionId }.toSet(), ids.toSet())
        assertEquals(ids.size, ids.toSet().size)
        items.forEach { item ->
            assertTrue(item.model.isOpenRouter)
            assertEquals(item.model.apiName, item.slug)
            assertEquals(item.model.vendor, item.provider)
            assertTrue(item.searchText.isNotEmpty())
        }
    }

    @Test
    fun testCopy_matchesSpeakCore() {
        assertEquals(asset.getString("browseButtonTitle"), OpenRouterBrowser.BROWSE_TITLE)
        assertEquals("Browse OpenRouter models…", OpenRouterBrowser.BROWSE_TITLE)
        assertEquals(asset.getString("cleanupTitle"), OpenRouterBrowser.CLEANUP_TITLE)
        assertEquals(asset.getString("useTitle"), OpenRouterBrowser.CLEANUP_USE)
        assertEquals(asset.getString("selectedTitle"), OpenRouterBrowser.CLEANUP_SELECTED)
        assertEquals(asset.getString("routeNote"), OpenRouterBrowser.CLEANUP_ROUTE_NOTE)
    }

    @Test
    fun testProviderFilter_listsEachVendorOnceAlphabetically() {
        val providers = OpenRouterBrowser.providers(OpenRouterBrowser.cleanupItems)
        assertEquals(providers.distinct(), providers)
        assertEquals(providers.sortedWith { a, b -> CleanupModelPicker.compareNatural(a, b) }, providers)
        val filter = OpenRouterBrowserFilter(provider = "OpenAI")
        val openAI = OpenRouterBrowser.filtered(OpenRouterBrowser.cleanupItems, filter)
        assertTrue(openAI.isNotEmpty())
        assertTrue(openAI.all { it.provider == "OpenAI" })
    }

    @Test
    fun testCleanupItems_skipRowsWithoutAnOfferedOpenRouterModel() {
        val spec = GeneratedCloudCatalog.openRouterCleanupModels.first()
        val native = CloudCatalog.cleanupModels.filterNot { it.isOpenRouter }
        assertTrue(OpenRouterBrowser.cleanupItems(listOf(spec), native).isEmpty())
        assertEquals(1, OpenRouterBrowser.cleanupItems(listOf(spec), CloudCatalog.cleanupModels).size)
    }
}
