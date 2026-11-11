package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `assets/cloud_catalog.json` is generated from SpeakCore (`CloudCatalogAndroidExport`, kept fresh by
 * `CloudCatalogAndroidExportTests`). [CloudCatalog] and [CleanupPolicy] must match it exactly, so a
 * catalogue, retirement, credential, wire-field or prompt change on the Mac fails here until Android
 * follows it.
 */
class CloudCatalogParityTest {
    private val asset = JSONObject(SettingsSearchAsset.locate("app/src/main/assets/cloud_catalog.json").readText())

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    @Test
    fun testAssetVersion_isUnderstood() {
        assertEquals(1, asset.getInt("version"))
    }

    @Test
    fun testProviders_matchIdsAndCredentialIdsInOrder() {
        val expected = asset.getJSONArray("providers").objects().map { it.getString("id") to it.getString("credentialId") }
        assertEquals(expected, CloudProvider.entries.map { it.id to it.credentialId })
        assertEquals(CloudProvider.entries, CloudCatalog.providers)
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
            )
        }
        val actual = CloudCatalog.transcriptionModels.map {
            listOf(it.catalogId, it.displayName, it.provider.id, it.apiName, it.languageField)
        }
        assertEquals(expected, actual)
        assertEquals(CloudCatalog.transcriptionModels.first(), CloudCatalog.defaultTranscriptionModel)
    }

    @Test
    fun testCleanup_matchesModelProviderAndPrompt() {
        val cleanup = asset.getJSONObject("cleanup")
        assertEquals(cleanup.getString("model"), CloudCatalog.CLEANUP_MODEL)
        assertEquals(cleanup.getString("provider"), CloudProvider.OpenRouter.id)
        assertEquals(cleanup.getString("systemPrompt"), CleanupPolicy.systemPrompt())
    }
}
