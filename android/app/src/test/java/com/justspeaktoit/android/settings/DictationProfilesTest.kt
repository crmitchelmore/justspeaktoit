package com.justspeaktoit.android.settings

import com.justspeaktoit.android.cloud.CloudCatalog
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android must store profiles in SpeakCore's `DictationProfile` shape, under the shared key. */
class DictationProfilesTest {
    private val profiles = JSONObject(SettingsSearchAsset.locate("app/src/main/assets/cloud_catalog.json").readText())
        .getJSONObject("profiles")

    @Test
    fun testStorageAndFields_matchTheSharedExport() {
        val fields = profiles.getJSONArray("fields").let { array -> (0 until array.length()).map(array::getString) }
        assertEquals(fields, DictationProfiles.fields)
        assertTrue("Android writes a field SpeakCore does not know", fields.containsAll(DictationProfiles.written))
        assertEquals(profiles.getString("storageKey"), AppPreferences.KEY_PROFILES)
        assertEquals(profiles.getString("cloudTranscriptionRouting"), DictationProfile.REMOTE_BATCH)
    }

    @Test
    fun testRoundTrip_keepsFieldsAndroidDoesNotEdit() {
        val stored = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work",
              "matchers":[{"kind":"bundleIdentifier","value":"com.apple.mail"}],
              "transcriptionModelID":"groq/whisper-large-v3-turbo","transcriptionRouting":"remoteBatch",
              "polishEnabled":true,"polishModelID":"native/anthropic/claude-haiku-5-5",
              "polishPrompt":"Write formally.","polishOutputLanguage":"en_GB","languageIdentifier":"en_GB"}]
        """.trimIndent()
        val profile = DictationProfiles.decode(stored).single()
        assertEquals("groq/whisper-large-v3-turbo", profile.cloudModel?.catalogId)
        assertEquals("en_GB", profile.language)
        assertEquals(true, profile.cleanupEnabled)
        assertEquals("native/anthropic/claude-haiku-5-5", profile.cleanupModel?.selectionId)
        assertEquals("Write formally.", profile.prompt)

        val renamed = JSONArray(DictationProfiles.encode(listOf(profile.copy(name = "Office", cleanupPrompt = null))))
            .getJSONObject(0)
        assertEquals("Office", renamed.getString("name"))
        assertEquals("en_GB", renamed.getString("polishOutputLanguage"))
        assertEquals("com.apple.mail", renamed.getJSONArray("matchers").getJSONObject(0).getString("value"))
        assertTrue("a cleared prompt is removed, not stored empty", !renamed.has("polishPrompt"))
    }

    @Test
    fun testAnotherPlatformsRoute_isNeverRunAsACloudUpload() {
        val streaming = DictationProfile(
            id = "A",
            name = "Live",
            transcriptionModelId = CloudCatalog.defaultTranscriptionModel.catalogId,
            transcriptionRouting = "remoteStreaming",
        )
        assertNull(streaming.cloudModel)
        assertNull(DictationProfile(id = "B", name = "Mac", transcriptionModelId = "apple/local/default").cloudModel)
    }

    @Test
    fun testNewProfile_usesAnUppercaseUuidAndTheSharedEmptyShape() {
        val created = DictationProfile.create("Notes").withCloudModel(CloudCatalog.defaultTranscriptionModel)
        assertEquals(created.id.uppercase(), created.id)
        val json = JSONArray(DictationProfiles.encode(listOf(created))).getJSONObject(0)
        assertEquals(0, json.getJSONArray("matchers").length())
        assertEquals("remoteBatch", json.getString("transcriptionRouting"))
        assertEquals(listOf(created), DictationProfiles.decode(DictationProfiles.encode(listOf(created)))
            .map { it.copy(source = null) })
    }

    @Test
    fun testMalformedOrUnnamedProfiles_areDropped() {
        assertEquals(emptyList<DictationProfile>(), DictationProfiles.decode("not json"))
        assertEquals(1, DictationProfiles.decode("""[{"id":"A"},{"id":"B","name":"Kept"}]""").size)
    }
}
