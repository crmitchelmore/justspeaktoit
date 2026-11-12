package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CleanupModelPickerTest {
    @Test
    fun testDirectGroup_hasOnlyNativeRoutesSortedByProviderThenModel() {
        val direct = CleanupModelPicker.direct()
        assertTrue(direct.none { it.isOpenRouter })
        assertEquals(
            listOf("Anthropic", "Google Gemini", "Groq", "Mistral", "OpenAI"),
            direct.map { it.vendor }.distinct(),
        )
        assertEquals("native/anthropic/claude-haiku-5-5", direct.first().selectionId)
        val openAI = direct.filter { it.provider == CloudProvider.OpenAI }.map { it.displayName }
        assertEquals(listOf("GPT-6 Luna", "GPT-6.1 Sol", "GPT-6.1 Terra"), openAI)
    }

    @Test
    fun testOpenRouterGroup_isSeparateAndSortedByVendor() {
        val openRouter = CleanupModelPicker.openRouter()
        assertTrue(openRouter.all { it.isOpenRouter && it.provider == CloudProvider.OpenRouter })
        assertEquals(
            listOf("Anthropic", "Google", "Mistral", "OpenAI", "Qwen"),
            openRouter.map { it.vendor }.distinct(),
        )
        // A model offered both ways is never a top-level OpenRouter entry.
        assertFalse(CleanupModelPicker.direct().any { it.selectionId == "openai/gpt-6-luna" })
        assertTrue(openRouter.any { it.selectionId == "openai/gpt-6-luna" })
    }

    @Test
    fun testNaturalOrder_isCaseInsensitiveAndNumeric() {
        assertTrue(CleanupModelPicker.compareNatural("GPT-5.4", "gpt-5.10") < 0)
        assertTrue(CleanupModelPicker.compareNatural("Alpha", "beta") < 0)
        assertEquals(0, CleanupModelPicker.compareNatural("openai", "OpenAI"))
    }

    @Test
    fun testSelectionLabel_namesOnlyTheOpenRouterRoute() {
        assertEquals(
            "OpenRouter › GPT-6 Luna",
            CleanupModelPicker.selectionLabel(CloudCatalog.cleanupModel("openai/gpt-6-luna")),
        )
        assertEquals("GPT-6 Luna", CleanupModelPicker.selectionLabel(CloudCatalog.cleanupModel("native/openai/gpt-6-luna")))
    }

    @Test
    fun testSavedChoices_keepTheirRouteAndUnknownFallsBackToDefault() {
        assertEquals(CloudProvider.OpenRouter, CloudCatalog.cleanupModel(null).provider)
        assertEquals(CloudCatalog.CLEANUP_MODEL, CloudCatalog.cleanupModel("gone/model").selectionId)
        assertEquals(CloudProvider.Anthropic, CloudCatalog.cleanupModel("native/anthropic/claude-sonnet-5-5").provider)
    }

    @Test
    fun testRemovedChoices_moveToTheirSuccessorOnTheSameRoute() {
        assertEquals(
            "native/anthropic/claude-sonnet-5-5",
            CloudCatalog.cleanupModel("native/anthropic/claude-sonnet-4-6").selectionId,
        )
        assertEquals("native/openai/gpt-6-luna", CloudCatalog.cleanupModel("native/openai/gpt-5.4-mini").selectionId)
        assertEquals("openai/gpt-6-luna", CloudCatalog.cleanupModel("openai/gpt-5.6-luna").selectionId)
    }

    @Test
    fun testCleanupRoutesToTheModelsOwnEndpointAndModelName() {
        val claude = CloudCatalog.cleanupModel("native/anthropic/claude-haiku-5-5")
        assertEquals("https://api.anthropic.com/v1/chat/completions", CloudWire.cleanupUrl(claude))
        val claudeBody = org.json.JSONObject(CloudWire.cleanupBody(claude.apiName, "x", CloudWire.cleanupMaxTokens(claude)))
        assertEquals("claude-haiku-5-5", claudeBody.getString("model"))
        assertEquals(CloudWire.ANTHROPIC_MAX_TOKENS, claudeBody.getInt("max_tokens"))
        val viaOpenRouter = CloudCatalog.cleanupModel("openai/gpt-6-luna")
        assertEquals(null, CloudWire.cleanupMaxTokens(viaOpenRouter))
        assertEquals("https://openrouter.ai/api/v1/chat/completions", CloudWire.cleanupUrl(viaOpenRouter))
    }

    @Test
    fun testSearch_matchesNameIdentifierAndVendor() {
        val all = CleanupModelPicker.openRouter()
        assertEquals(all, CleanupModelPicker.filter(all, "  "))
        assertTrue(CleanupModelPicker.filter(all, "qwen").all { it.vendor == "Qwen" })
        assertTrue(CleanupModelPicker.filter(all, "nothing-matches").isEmpty())
    }
}
