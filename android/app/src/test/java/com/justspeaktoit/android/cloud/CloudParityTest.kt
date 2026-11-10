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
        // Some catalogue IDs are named constants declared in OpenAITranscriptionModels.swift.
        val catalog = RepoSources.speakCore("ModelCatalog.swift") +
            RepoSources.speakCore("OpenAITranscriptionModels.swift")
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
        assertEquals(
            listOf("openai.apiKey", "groq.apiKey", "openrouter.apiKey", "anthropic.apiKey", "google.apiKey", "mistral.apiKey"),
            CloudProvider.entries.map { it.credentialId },
        )
    }

    @Test
    fun testLanguageField_followsSwiftSelectionRule() {
        val swift = RepoSources.speakCore("OpenAITranscriptionModels.swift")
        val constants = swiftStringConstants(swift)
        assertTrue(swift.contains("usesLanguageHintsArray(apiModelName) ? \"languages[]\" : \"language\""))
        // The families named inside usesLanguageHintsArray, resolved to their API names.
        val body = swift.substringAfter("func usesLanguageHintsArray").substringBefore("\n    }")
        val families = Regex("belongs\\(apiModelName, to: (\\w+)\\)").findAll(body)
            .map { constants.getValue(it.groupValues[1]) }.toList()
        assertTrue("No language-hint families found", families.isNotEmpty())
        CloudCatalog.transcriptionModels.forEach { model ->
            val name = model.apiName.lowercase()
            val usesArray = families.any { name == it || name.startsWith("$it-") }
            assertEquals(model.catalogId, if (usesArray) "languages[]" else "language", model.languageField)
        }
    }

    /**
     * Android offers every non-retiring model of the providers it implements, so a model added to
     * the Mac catalogue fails this test until Android supports it or records why it cannot.
     */
    @Test
    fun testTranscriptionModels_coverEveryNonRetiringMacModelForSupportedProviders() {
        val openAI = RepoSources.speakCore("OpenAITranscriptionModels.swift")
        val constants = swiftStringConstants(openAI)
        val direct = openAI.substringAfter("directBatchModelIDs: Set<String> = [").substringBefore("]")
            .split(",").map { it.trim() }.filter { it.isNotEmpty() }
            .map { if (it.startsWith("\"")) it.trim('"') else constants.getValue(it) }
        val catalog = RepoSources.speakCore("ModelCatalog.swift")
        val groq = Regex("id: \"(groq/[^\"]+)\"").findAll(catalog).map { it.groupValues[1] }.toSet()
        val retirements = RepoSources.speakCore("ModelRetirements.swift")
        val retiring = Regex("id: \"([^\"]+)\", mode: \\.batch").findAll(retirements).map { it.groupValues[1] }.toSet()
        val expected = (direct + groq).toSet() - retiring - ANDROID_EXCLUSIONS.keys
        assertEquals(expected, CloudCatalog.transcriptionModels.map { it.catalogId }.toSet())
    }

    @Test
    fun testNativeCleanupModels_matchNativeTextModels() {
        val swift = RepoSources.speakCore("NativeTextModels.swift")
        val providerIds = Regex("static let (\\w+) = NativeTextProvider\\(\\s*id: \"([^\"]+)\"")
            .findAll(swift).associate { it.groupValues[1] to it.groupValues[2] }
        val expected = Regex("option\\((\\w+), \"([^\"]+)\", \"([^\"]+)\"").findAll(swift).map {
            Triple("native/${providerIds.getValue(it.groupValues[1])}/${it.groupValues[2]}", it.groupValues[3], it.groupValues[2])
        }.toList()
        assertTrue("No native models parsed", expected.isNotEmpty())
        val android = CloudCatalog.cleanupModels.filterNot { it.isOpenRouter }
            .map { Triple(it.selectionId, it.displayName, it.apiName) }
        assertEquals(expected.toSet(), android.toSet())
    }

    @Test
    fun testNativeCleanupEndpoints_matchNativeTextModels() {
        val swift = RepoSources.speakCore("NativeTextModels.swift")
        val urls = Regex("id: \"([^\"]+)\", displayName: \"[^\"]+\",\\s*chatCompletionsURL: URL\\(string: \"([^\"]+)\"\\)")
            .findAll(swift).associate { it.groupValues[1] to it.groupValues[2] }
        CloudCatalog.cleanupModels.filterNot { it.isOpenRouter }.map { it.provider }.distinct().forEach { provider ->
            assertEquals(provider.id, urls[provider.id], "${provider.baseUrl}/chat/completions")
        }
    }

    @Test
    fun testOpenRouterCleanupModels_matchModelCatalogue() {
        val catalog = RepoSources.speakCore("ModelCatalog.swift")
        val section = catalog.substringAfter("NativeTextModels.postProcessing + [")
            .substringBefore("public static let localTranscription")
        val expected = Regex("id: \"([^\"]+)\",\\s*displayName: \"([^\"]+)\"").findAll(section)
            .map { it.groupValues[1] to it.groupValues[2] }.toSet()
        assertTrue("No OpenRouter cleanup models parsed", expected.isNotEmpty())
        val android = CloudCatalog.cleanupModels.filter { it.isOpenRouter }.map { it.selectionId to it.displayName }.toSet()
        assertEquals(expected, android)
    }

    private fun swiftStringConstants(swift: String): Map<String, String> =
        Regex("static let (\\w+) = \"([^\"]+)\"").findAll(swift).associate { it.groupValues[1] to it.groupValues[2] }

    private companion object {
        /** Mac models Android deliberately does not offer, with the reason. Empty today. */
        val ANDROID_EXCLUSIONS: Map<String, String> = emptyMap()
    }
}
