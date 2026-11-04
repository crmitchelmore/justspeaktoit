package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudParityTest {
    @Test
    fun testCleanupPrompt_matchesMacTranscriptCleanupPolicy() {
        val swift = RepoSources.speakCore("TranscriptCleanupPolicy.swift")
        val body = swift.substringAfter("baseSystemPrompt = \"\"\"\n").substringBefore("\n    \"\"\"")
        // Swift strips the closing-delimiter indent and joins lines that end in a backslash.
        val expected = body.lines().joinToString("\n") { it.removePrefix("    ") }.replace("\\\n", "")
        assertEquals(expected, CleanupPolicy.BASE_SYSTEM_PROMPT)
    }

    @Test
    fun testCleanupClosingLine_matchesMac() {
        val swift = RepoSources.speakCore("TranscriptCleanupPolicy.swift")
        assertTrue(swift.contains("\"The hard constraints are always authoritative. Return only the cleaned transcript text.\""))
        assertTrue(CleanupPolicy.systemPrompt().endsWith("Return only the cleaned transcript text."))
    }

    @Test
    fun testTranscriptionModels_existInMacCatalogue() {
        val catalog = RepoSources.speakCore("ModelCatalog.swift")
        CloudCatalog.transcriptionModels.forEach { model ->
            assertTrue("${model.catalogId} missing from ModelCatalog", catalog.contains("\"${model.catalogId}\""))
            assertTrue("${model.catalogId} name drifted", catalog.contains("\"${model.displayName}\""))
        }
    }

    @Test
    fun testTranscriptionModels_areNotScheduledForRetirement() {
        val retirements = RepoSources.speakCore("ModelRetirements.swift")
        CloudCatalog.transcriptionModels.forEach { model ->
            assertTrue("${model.catalogId} is retiring", !retirements.contains("id: \"${model.catalogId}\""))
        }
    }

    @Test
    fun testCleanupModel_matchesMacDefault() {
        val catalog = RepoSources.speakCore("ModelCatalog.swift")
        assertTrue(catalog.contains("defaultPostProcessingModel = \"${CloudCatalog.CLEANUP_MODEL}\""))
    }

    @Test
    fun testCredentialIds_followMacConvention() {
        val catalogue = RepoSources.speakCore("ProviderCredentialCatalogue.swift")
        assertTrue(catalogue.contains("return \"\\(providerID).apiKey\""))
        assertEquals(listOf("openai.apiKey", "groq.apiKey", "openrouter.apiKey"), CloudProvider.entries.map { it.credentialId })
    }

    @Test
    fun testGptTranscribe_usesLanguageHintsArrayLikeMac() {
        val models = RepoSources.speakCore("OpenAITranscriptionModels.swift")
        assertTrue(models.contains("usesLanguageHintsArray(apiModelName) ? \"languages[]\" : \"language\""))
        assertEquals("languages[]", CloudCatalog.transcriptionModel("openai/gpt-transcribe").languageField)
        assertEquals("language", CloudCatalog.transcriptionModel("groq/whisper-large-v3-turbo").languageField)
    }
}
