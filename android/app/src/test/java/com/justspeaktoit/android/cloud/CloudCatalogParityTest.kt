package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `assets/cloud_catalog.json` is generated from SpeakCore (`CloudCatalogAndroidExport`, kept fresh by
 * `CloudCatalogAndroidExportTests`), and the build generates [GeneratedCloudCatalog] from it. These
 * tests are the one golden drift check on that generator: [CloudCatalog] and [CleanupPolicy] must
 * expose exactly what the asset says, and every provider needs an Android transport.
 */
class CloudCatalogParityTest {
    private val asset = JSONObject(SettingsSearchAsset.locate("app/src/main/assets/cloud_catalog.json").readText())

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    @Test
    fun testAssetVersion_isUnderstood() {
        assertEquals(1, asset.getInt("version"))
        assertEquals(asset.getInt("version"), GeneratedCloudCatalog.VERSION)
    }

    @Test
    fun testProviders_matchIdsAndCredentialIdsInOrder() {
        val expected = asset.getJSONArray("providers").objects().map { it.getString("id") to it.getString("credentialId") }
        assertEquals(expected, CloudCatalog.providers.map { it.id to it.credentialId })
    }

    @Test
    fun testEveryTransport_belongsToAGeneratedProvider() {
        assertEquals(
            "a CloudProvider transport with no catalogue provider is dead code",
            CloudProvider.entries.map { it.id }.toSet(),
            CloudCatalog.providers.map { it.id }.toSet(),
        )
    }

    @Test
    fun testTranscriptionModels_matchTheGeneratedCatalogueInOrder() {
        val expected = asset.getJSONArray("transcriptionModels").objects().map {
            listOf(
                it.getString("catalogId"),
                it.getString("displayName"),
                it.getString("provider"),
                it.getString("apiName"),
                it.getString("languageField"),
                it.getBoolean("supportsPrompt").toString(),
            )
        }
        val actual = CloudCatalog.transcriptionModels.map {
            listOf(it.catalogId, it.displayName, it.provider.id, it.apiName, it.languageField, it.supportsPrompt.toString())
        }
        assertEquals(expected, actual)
        assertEquals(CloudCatalog.transcriptionModels.first(), CloudCatalog.defaultTranscriptionModel)
    }

    @Test
    fun testCleanup_matchesModelProviderAndPrompt() {
        val cleanup = asset.getJSONObject("cleanup")
        assertEquals(cleanup.getString("model"), CloudCatalog.CLEANUP_MODEL)
        assertEquals(cleanup.getString("provider"), CloudCatalog.cleanupProvider.id)
        assertEquals(cleanup.getString("systemPrompt"), CleanupPolicy.systemPrompt())
    }

    @Test
    fun testCleanupModels_matchTheGeneratedCatalogueInOrder() {
        val expected = asset.getJSONArray("cleanupModels").objects().map {
            listOf(it.getString("selectionId"), it.getString("displayName"), it.getString("provider"), it.getString("apiName"))
        }
        val actual = CloudCatalog.cleanupModels.map { listOf(it.selectionId, it.displayName, it.provider.id, it.apiName) }
        assertEquals(expected, actual)
        assertEquals(CloudCatalog.CLEANUP_MODEL, CloudCatalog.cleanupModel(null).selectionId)
    }

    @Test
    fun testCleanupModelSuccessors_matchTheGeneratedCatalogue() {
        val successors = asset.getJSONObject("cleanupModelSuccessors")
        assertTrue(successors.length() > 0)
        successors.keys().forEach { removed ->
            assertEquals(successors.getString(removed), CloudCatalog.cleanupModel(removed).selectionId)
        }
    }

    @Test
    fun testNativeCleanupEndpoints_matchSpeakCore() {
        val urls = asset.getJSONArray("providers").objects()
            .filter { it.has("chatCompletionsURL") }
            .associate { it.getString("id") to it.getString("chatCompletionsURL") }
        CloudCatalog.cleanupModels.filterNot { it.isOpenRouter }.map { it.provider }.distinct().forEach { provider ->
            assertEquals(provider.id, urls[provider.id], "${provider.baseUrl}/chat/completions")
        }
    }

    @Test
    fun testLanguagesAndVocabularyPromptRules_matchTheGeneratedCatalogue() {
        val expected = asset.getJSONArray("languages").objects().map { it.getString("id") to it.getString("displayName") }
        assertEquals(expected, DictationLanguages.all.map { it.id to it.displayName })
        val prompt = asset.getJSONObject("keywordPrompt")
        assertEquals(prompt.getInt("maximumBytes"), GeneratedCloudCatalog.KEYWORD_PROMPT_MAX_BYTES)
        assertEquals(prompt.getInt("maximumTerms"), GeneratedCloudCatalog.KEYWORD_PROMPT_MAX_TERMS)
    }
}
