package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/** The region, endpoint and workspace encodings shared with the Apple apps' credentials. */
class RegionalCredentialsTest {
    @Test
    fun testAzure_storesKeyColonRegionAndKeepsAPastedRegion() {
        assertEquals("abc:uksouth", AzureSpeechCredential.credentialsForSaving(" abc ", " UKSouth "))
        assertEquals("abc:eastus2", AzureSpeechCredential.credentialsForSaving("abc:eastus2", "westus"))
        assertNull(AzureSpeechCredential.credentialsForSaving("abc", ""))
        assertNull(AzureSpeechCredential.credentialsForSaving("abc", "west-us"))
        assertNull(AzureSpeechCredential.credentialsForSaving("local-proxy/token", "eastus"))
        assertNull(AzureSpeechCredential.credentialsForSaving("abc\ndef", "eastus"))
        assertEquals(AzureSpeechCredential.Parsed("abc", "eastus"), AzureSpeechCredential.parse("abc"))
        assertEquals(AzureSpeechCredential.Parsed("abc", "westeurope"), AzureSpeechCredential.parse("abc: WestEurope"))
    }

    @Test
    fun testAzure_acceptsOnlyASpeechResourceOrigin() {
        assertEquals(
            "https://speak.cognitiveservices.azure.com",
            AzureSpeechCredential.resourceOrigin(" https://Speak.cognitiveservices.azure.com/ "),
        )
        assertEquals("https://hub.services.ai.azure.com", AzureSpeechCredential.resourceOrigin("https://hub.services.ai.azure.com"))
        listOf(
            "http://speak.cognitiveservices.azure.com",
            "https://speak.cognitiveservices.azure.com/speechtotext",
            "https://speak.cognitiveservices.azure.com:8443",
            "https://speak.cognitiveservices.azure.com?x=1",
            "https://user@speak.cognitiveservices.azure.com",
            "https://example.com",
            "http://127.0.0.1:5000",
        ).forEach { assertNull(it, AzureSpeechCredential.resourceOrigin(it)) }

        val connection = AzureSpeechCredential.connection("abc:eastus", "https://speak.cognitiveservices.azure.com")
        assertEquals(AzureSpeechCredential.Connection("https://speak.cognitiveservices.azure.com", "abc"), connection)
        val error = assertThrows(CloudException::class.java) {
            AzureSpeechCredential.connection("abc:eastus", "https://example.com")
        }
        assertEquals(DictationFailure.InvalidKey, error.failure)
    }

    @Test
    fun testAlibaba_encodesRegionWorkspaceAndKeyAsTheAppleAppsDo() {
        val saved = AlibabaCredential.credentialsForSaving(" sk-1 ", AlibabaCredential.Region.Beijing, " LLM-abc ")
        assertEquals("""{"region":"cn-beijing","workspace":"llm-abc","apiKey":"sk-1"}""", saved)
        val parsed = AlibabaCredential.parse(checkNotNull(saved))
        assertEquals(AlibabaCredential.Parsed(AlibabaCredential.Region.Beijing, "llm-abc", "sk-1"), parsed)
        assertEquals("https://llm-abc.cn-beijing.maas.aliyuncs.com", parsed?.origin)

        assertNull(AlibabaCredential.credentialsForSaving("sk-1", null, "llm-abc"))
        for (workspace in listOf("", "trial", "-abc", "abc-", "llm_abc", "llm.abc", "a".repeat(64))) {
            assertNull(workspace, AlibabaCredential.credentialsForSaving("sk-1", AlibabaCredential.Region.Tokyo, workspace))
        }
        assertNull(AlibabaCredential.parse("sk-1"))
        assertNull(AlibabaCredential.parse("""{"region":"mars-1","workspace":"llm-abc","apiKey":"sk-1"}"""))
    }

    @Test
    fun testStepFun_tagsNewKeysWithTheirRegionAndTreatsPlainKeysAsChina() {
        assertEquals(
            """{"apiKey":"sk","region":"international"}""",
            StepFunCredential.credentialsForSaving(" sk ", StepFunCredential.Region.International),
        )
        assertEquals(
            """{"apiKey":"sk","region":"china"}""",
            StepFunCredential.credentialsForSaving("""{"region":"china","apiKey":"sk"}""", StepFunCredential.Region.International),
        )
        assertNull(StepFunCredential.credentialsForSaving("", StepFunCredential.Region.China))
        assertNull(StepFunCredential.credentialsForSaving("{not json", StepFunCredential.Region.China))
        assertEquals(StepFunCredential.Parsed(StepFunCredential.Region.China, "legacy"), StepFunCredential.parse("legacy"))
        assertNull(StepFunCredential.parse("""{"apiKey":"sk","region":"moon"}"""))
    }
}
