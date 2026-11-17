package com.justspeaktoit.android.local

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LlamaCatalogTest {
    private val json by lazy {
        SettingsSearchAsset.locate("app/src/main/assets/${LlamaCatalog.ASSET}").readText()
    }
    private val asset by lazy { LlamaCatalog.parse(json) }

    @Test
    fun testAsset_offersTheDesktopCleanupModelsUnderTheirSharedIdentifiers() {
        assertEquals(
            listOf("qwen3-1.7b-q4", "qwen3-0.6b-q4", "smollm2-360m-instruct-q4").map { "local/post-processing/$it" },
            asset.map { it.catalogId },
        )
        asset.forEach { model ->
            assertTrue(model.url, model.url.startsWith("https://huggingface.co/${model.repository}/resolve/"))
            assertTrue(model.url, model.url.endsWith("/${model.filename}"))
            assertTrue(model.filename, model.filename.endsWith(".gguf"))
            assertEquals(64, model.sha256.length)
            assertTrue(model.bytes > 0)
        }
        val gated = asset.filter { it.minimumDeviceMemoryBytes != null }
        assertEquals(listOf("local/post-processing/qwen3-1.7b-q4"), gated.map { it.catalogId })
    }

    @Test
    fun testParse_rejectsAnotherNamespaceOrAnUnsafePin() {
        fun mutated(change: JSONObject.() -> Unit): String {
            val root = JSONObject(json)
            root.getJSONArray("models").getJSONObject(0).change()
            return root.toString()
        }
        listOf<JSONObject.() -> Unit>(
            { put("catalogId", "local/whisperkit/base") },
            { put("url", getString("url").replaceFirst("https://", "http://")) },
            { put("url", "https://example.com/${getString("filename")}") },
            { put("filename", "../model.gguf") },
            { put("filename", "model.bin") },
            { put("sha256", "abc") },
            { put("bytes", 0) },
        ).forEach { change ->
            assertThrows(IllegalArgumentException::class.java) { LlamaCatalog.parse(mutated(change)) }
        }
    }

    @Test
    fun testFind_matchesOnlyCleanupCatalogueIds() {
        assertEquals(
            "local/post-processing/qwen3-0.6b-q4",
            PinnedModels.find(asset, "local/post-processing/qwen3-0.6b-q4")?.catalogId,
        )
        assertNull(PinnedModels.find(asset, "local/whisperkit/base"))
        assertNull(PinnedModels.find(asset, "openrouter/openai/gpt-4o-mini"))
    }
}
