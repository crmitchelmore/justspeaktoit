package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
        val ids = items.map { it.selectionId }
        assertEquals((0 until exported.length()).map { exported.getJSONObject(it).getString("selectionId") }, ids)
        assertEquals(CleanupModelPicker.openRouter().map { it.selectionId }.toSet(), ids.toSet())
        assertEquals(ids.size, ids.toSet().size)
        items.forEach { item ->
            val model = CloudCatalog.findCleanupModel(item.selectionId)!!
            assertTrue(model.isOpenRouter)
            assertEquals(model.apiName, item.slug)
            assertEquals(model.vendor, item.provider)
            assertTrue(item.searchText.isNotEmpty())
            assertFalse(item.discovered)
        }
    }

    @Test
    fun testCleanupItems_addDiscoveredOpenAIModelsOnlyWhileDiscoveryIsOn() {
        val bundled = OpenRouterBrowser.cleanupItems.first { it.provider == "OpenAI" }
        val found = listOf(
            DiscoveredCleanupModel("openai/gpt-future", "GPT Future", 0.1, 0.5, 1_050_000),
            DiscoveredCleanupModel("openai/gpt-future", "GPT Future again", null, null, null),
            DiscoveredCleanupModel(bundled.slug, "Already bundled", null, null, null),
        )
        val off = OpenRouterBrowser.cleanupItems(found, discoveryEnabled = false, selected = null)
        assertEquals(OpenRouterBrowser.cleanupItems.map { it.selectionId }.toSet(), off.map { it.selectionId }.toSet())

        val on = OpenRouterBrowser.cleanupItems(found, discoveryEnabled = true, selected = null)
        val discovered = on.filter { it.discovered }
        assertEquals(listOf("openrouter/cleanup/openai/gpt-future"), discovered.map { it.selectionId })
        val item = discovered.single()
        assertEquals("GPT Future (discovered)", item.name)
        assertEquals("OpenAI", item.provider)
        assertEquals("\$0.10/\$0.50 / 1M", item.pricing)
        assertTrue(item.unqualified)
        assertEquals(on.size, OpenRouterBrowser.cleanupItems.size + 1)
        assertEquals(
            on.sortedWith { a, b ->
                CleanupModelPicker.compareNatural(a.provider, b.provider).takeIf { it != 0 }
                    ?: CleanupModelPicker.compareNatural(a.name, b.name)
            },
            on,
        )
    }

    @Test
    fun testCleanupItems_keepASavedDiscoveredModelThatIsNoLongerListed() {
        val saved = "openrouter/cleanup/openai/gpt-retired"
        val items = OpenRouterBrowser.cleanupItems(emptyList(), discoveryEnabled = false, selected = saved)
        val retained = items.single { it.discovered }
        assertEquals(saved, retained.selectionId)
        assertEquals("openai/gpt-retired (saved discovery)", retained.name)
        val model = CloudCatalog.findCleanupModel(saved)!!
        assertEquals(CloudProvider.OpenRouter, model.provider)
        assertEquals("openai/gpt-retired", model.apiName)
        assertEquals(saved, CloudCatalog.cleanupModel(saved).selectionId)
        assertNull(CloudCatalog.findCleanupModel("openrouter/cleanup/anthropic/claude"))
    }

    @Test
    fun testTranscriptionItems_areTheBundledModelsThenLiveSpeechToTextModelsByName() {
        val bundled = OpenRouterBrowser.transcriptionItems
        assertTrue(bundled.isNotEmpty())
        bundled.forEach { item ->
            val model = CloudCatalog.findTranscriptionModel(item.selectionId)!!
            assertEquals(CloudProvider.OpenRouter, model.provider)
            assertTrue(CloudCatalog.isOpenRouterTranscription(model))
        }
        val audio = { id: String, name: String, output: String ->
            OpenRouterAudioModel(id, name, "", listOf("audio"), listOf(output), mapOf("audio" to "0"), null)
        }
        val items = OpenRouterBrowser.transcriptionItems(
            listOf(
                audio("vendor/zeta", "Zeta", "transcription"),
                audio("vendor/alpha", "Alpha", "transcription"),
                audio("vendor/alpha", "Alpha again", "transcription"),
                audio("vendor/voice", "Voice", "speech"),
            ),
        )
        assertEquals(bundled, items.take(bundled.size))
        val live = items.drop(bundled.size)
        assertEquals(
            listOf("openrouter/transcription/vendor/alpha", "openrouter/transcription/vendor/zeta"),
            live.map { it.selectionId },
        )
        assertTrue(live.all { it.discovered && it.hasZeroPrices })
        assertEquals(mapOf("audio" to "0"), live.first().listedPrices)
        assertEquals("https://openrouter.ai/vendor/alpha", live.first().modelPageUrl)
        assertNull(OpenRouterBrowser.modelPageUrl("a/b/c"))
    }

    @Test
    fun testFindTranscriptionModel_routesASavedLiveModelToOpenRouter() {
        val model = CloudCatalog.transcriptionModel("openrouter/transcription/vendor/new-model")
        assertEquals(CloudProvider.OpenRouter, model.provider)
        assertEquals("vendor/new-model", model.apiName)
        assertEquals("openrouter/transcription/vendor/new-model", model.catalogId)
        assertEquals("OpenRouter › Whisper", OpenRouterBrowser.selectionLabel("Whisper"))
        assertNull(CloudCatalog.findTranscriptionModel("openrouter/transcription/bad"))
        assertEquals(CloudCatalog.defaultTranscriptionModel, CloudCatalog.transcriptionModel("acme/unknown"))
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
