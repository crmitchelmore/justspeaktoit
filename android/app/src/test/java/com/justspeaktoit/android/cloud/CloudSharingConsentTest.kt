package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudSharingConsentTest {
    @Test
    fun grantIsPerKindAndWithdraws() {
        val audio = request("deepgram", CloudSharedDataKind.Audio)
        val speech = request("deepgram", CloudSharedDataKind.TextToSpeak)
        var consent = CloudSharingConsent()
        assertFalse(consent.allows(audio))
        consent = consent.granting(audio)
        assertTrue(consent.allows(audio))
        assertFalse(consent.allows(speech))
        consent = consent.withdrawing("deepgram")
        assertTrue(consent.grantedProviderIds().isEmpty())
    }

    @Test
    fun jsonMatchesTheSharedDocumentAndFailsClosed() {
        val consent = CloudSharingConsent().granting(request("openrouter", CloudSharedDataKind.Transcript))
        val decoded = CloudSharingConsent.decode(consent.encoded())
        assertTrue(decoded.allows("openrouter", CloudSharedDataKind.Transcript))
        assertTrue(consent.encoded().contains("\"version\":1"))
        assertFalse(CloudSharingConsent.decode("not json").allows("openrouter", CloudSharedDataKind.Transcript))
        assertFalse(CloudSharingConsent.decode("{\"grants\":{},\"version\":2}").grantedProviderIds().isNotEmpty())
        val partial = CloudSharingConsent.decode("{\"grants\":{\"deepgram\":[\"audio\",\"nope\"]},\"version\":1}")
        assertTrue(partial.allows("deepgram", CloudSharedDataKind.Audio))
        assertFalse(partial.allows("deepgram", CloudSharedDataKind.Transcript))
    }

    @Test
    fun kindWireValuesRoundTrip() {
        assertEquals(CloudSharedDataKind.Audio, CloudSharedDataKind.fromWire("audio"))
        assertEquals(CloudSharedDataKind.Transcript, CloudSharedDataKind.fromWire("transcript"))
        assertEquals(null, CloudSharedDataKind.fromWire("nope"))
    }

    @Test
    fun blockedMessageMatchesSpeakCore() {
        val message = CloudSharingConsent.blockedMessage(request("deepgram", CloudSharedDataKind.Audio))
        assertEquals(
            "Nothing was sent to Deepgram. Open Just Speak to It and allow your audio to be sent to Deepgram, " +
                "or choose an on-device option.",
            message,
        )
    }

    @Test
    fun exportedCatalogueNamesEveryAndroidProvider() {
        val json = SettingsSearchAsset.locate("app/src/main/assets/cloud_sharing_providers.json").readText()
        val providers = CloudSharingProviders.load(json)
        val ids = providers.map { it.id }.toSet()
        CloudProvider.entries.forEach { provider ->
            assertTrue("${provider.id} missing from cloud_sharing_providers.json", provider.id in ids)
        }
        providers.forEach { assertTrue(it.privacyPolicyUrl.startsWith("https://")) }
    }

    private fun request(id: String, kind: CloudSharedDataKind) = CloudSharingRequest(
        CloudSharingProvider(id, if (id == "deepgram") "Deepgram" else "OpenRouter", "https://example.com/privacy"),
        listOf(kind),
        canUseOnDevice = true,
    )
}
