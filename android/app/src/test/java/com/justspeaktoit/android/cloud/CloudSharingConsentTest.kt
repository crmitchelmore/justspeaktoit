package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.readaloud.VoiceCatalog
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Android side of SpeakCore's `CloudSharingConsent` (#1805): the same rules and the same stored JSON. */
class CloudSharingConsentTest {
    private fun request(id: String, kind: CloudSharedDataKind) =
        CloudSharingConsent.request(CloudProvider.entries.first { it.id == id }, kind)

    private val openAI = request("openai", CloudSharedDataKind.Audio)
    private val deepgramAudio = request("deepgram", CloudSharedDataKind.Audio)

    @Test
    fun testEncode_writesTheAppleStoreFormat() {
        val consent = CloudSharingConsent(
            mapOf(
                "openrouter" to setOf(CloudSharedDataKind.TextToSpeak, CloudSharedDataKind.TranscriptText),
                "deepgram" to setOf(CloudSharedDataKind.Audio),
            ),
        )
        val json = """{"grants":{"deepgram":["audio"],"openrouter":["transcriptText","textToSpeak"]},"version":1}"""
        assertEquals(json, consent.encode())
        assertEquals(consent, CloudSharingConsent.decode(json))
    }

    @Test
    fun testDecode_unreadableOrUnknownIsNoConsent() {
        assertEquals(CloudSharingConsent(), CloudSharingConsent.decode(null))
        assertEquals(CloudSharingConsent(), CloudSharingConsent.decode("not json"))
        assertEquals(CloudSharingConsent(), CloudSharingConsent.decode("""{"grants":{"openai":["video"]},"version":1}"""))
    }

    @Test
    fun testMissing_dropsAllowedKindsAndWithdrawAsksAgain() {
        val both = CloudSharingConsent.merged(
            listOf(request("openai", CloudSharedDataKind.TranscriptText), openAI, deepgramAudio),
        )
        assertEquals(listOf(CloudSharedDataKind.Audio, CloudSharedDataKind.TranscriptText), both.first().kinds)
        val consent = CloudSharingConsent().granting(listOf(openAI))
        val missing = consent.missing(both)
        assertEquals(
            listOf("openai" to listOf(CloudSharedDataKind.TranscriptText), "deepgram" to listOf(CloudSharedDataKind.Audio)),
            missing.map { it.provider.id to it.kinds },
        )
        assertEquals(emptyList<CloudSharingRequest>(), consent.granting(missing).missing(both))
        assertEquals(both.take(1).map { it.provider.id }, consent.allowed.map { it.provider.id })
        assertEquals(listOf(openAI), consent.withdrawing("openai").missing(listOf(openAI)))
    }

    @Test
    fun testCopy_namesTheProviders() {
        assertEquals("OpenAI and Deepgram", CloudSharingConsent.formattedList(listOf("OpenAI", "Deepgram")))
        assertEquals("A, B and C", CloudSharingConsent.formattedList(listOf("A", "B", "C")))
        val intro = CloudSharingConsent.sheetIntro(listOf(openAI))
        assertTrue(intro, intro.contains("OpenAI") && !intro.contains("{"))
        assertTrue(CloudSharingConsent.blockedMessage(listOf(openAI, deepgramAudio)).contains("OpenAI and Deepgram"))
    }

    @Test
    fun testGeneratedPolicy_coversEveryKindProviderAndVoice() {
        assertEquals(
            CloudSharedDataKind.entries.map { it.id },
            GeneratedCloudCatalog.cloudSharingKinds.map { it.id },
        )
        val catalogued = GeneratedCloudCatalog.cloudSharingProviders.associateBy { it.id }
        CloudProvider.entries.forEach {
            assertTrue("${it.id} has no privacy policy", catalogued[it.id]?.privacyPolicyUrl != null)
        }
        val voices = VoiceCatalog.parse(SettingsSearchAsset.locate("app/src/main/assets/${VoiceCatalog.ASSET}").readText())
        voices.voices.map { it.provider }.toSet().forEach { assertTrue("voice provider $it is not catalogued", it in catalogued) }
        assertEquals(GeneratedCloudCatalog.CLOUD_SHARING_STORAGE_KEY, AppPreferences.KEY_CLOUD_SHARING_CONSENT)
    }
}
