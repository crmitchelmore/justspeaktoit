package com.justspeaktoit.android.local

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WhisperCatalogTest {
    private val asset by lazy {
        WhisperCatalog.parse(SettingsSearchAsset.locate("app/src/main/assets/${WhisperCatalog.ASSET}").readText())
    }

    @Test
    fun testAsset_offersTheSharedPinsUnderTheirSharedIdentifiers() {
        assertEquals(
            listOf("tiny", "base", "small", "large-v3-turbo").map { "local/whisperkit/$it" },
            asset.map { it.catalogId },
        )
        asset.forEach { model ->
            assertTrue(model.url, model.url.startsWith("https://huggingface.co/"))
            assertEquals(64, model.sha256.length)
            assertTrue(model.bytes > 0)
            assertEquals("MIT", model.license)
        }
        val turbo = asset.single { it.catalogId.endsWith("large-v3-turbo") }
        assertEquals("q5_0", turbo.quantization)
        assertTrue(asset.filter { it != turbo }.all { it.minimumDeviceMemoryBytes == null })
    }

    @Test
    fun testOffered_hidesModelsThatNeedMoreMemory_unlessAlreadyDownloaded() {
        val turbo = asset.single { it.minimumDeviceMemoryBytes != null }
        val small = checkNotNull(turbo.minimumDeviceMemoryBytes) - 1
        assertFalse(turbo in WhisperCatalog.offered(asset, small, installed = emptySet()))
        assertTrue(turbo in WhisperCatalog.offered(asset, small, installed = setOf(turbo.catalogId)))
        assertEquals(asset, WhisperCatalog.offered(asset, Long.MAX_VALUE, installed = emptySet()))
    }

    @Test
    fun testFind_matchesOnlyCatalogueIds() {
        assertEquals("local/whisperkit/base", WhisperCatalog.find(asset, "local/whisperkit/base")?.catalogId)
        assertNull(WhisperCatalog.find(asset, "apple/local/en-GB"))
        assertNull(WhisperCatalog.find(asset, null))
    }

    @Test
    fun testAllowsHost_acceptsExactHostsAndSubdomainsOnly() {
        val model = pinnedModel()
        assertTrue(model.allowsHost("huggingface.co"))
        assertTrue(model.allowsHost("cdn-lfs.HF.co"))
        assertFalse(model.allowsHost("evilhf.co"))
        assertFalse(model.allowsHost("huggingface.co.example.com"))
        assertFalse(model.allowsHost(""))
    }

    @Test
    fun testParse_rejectsUntrustedUrlsMissingPinsAndUnsafeFilenames() {
        fun withField(key: String, value: Any) = JSONObject(SettingsSearchAsset.locate(
            "app/src/main/assets/${WhisperCatalog.ASSET}",
        ).readText()).also { root ->
            root.put("models", JSONArray().put(root.getJSONArray("models").getJSONObject(0).put(key, value)))
        }.toString()
        listOf(
            "url" to "http://huggingface.co/ggml-tiny.bin",
            "url" to "https://example.com/ggml-tiny.bin",
            "sha256" to "abc",
            "bytes" to 0,
            "filename" to "../ggml-tiny.bin",
        ).forEach { (key, value) ->
            assertThrows("$key=$value", IllegalArgumentException::class.java) {
                WhisperCatalog.parse(withField(key, value))
            }
        }
    }
}
