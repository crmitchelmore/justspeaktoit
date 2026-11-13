package com.justspeaktoit.android.settings

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.Retention
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The raw configuration against the schema SpeakCore exports (`assets/settings_schema.json`). When a
 * preference is added, give it a field in `SettingsSchema+Android.swift`, regenerate the asset with
 * `scripts/update-android-assets` and bind it in [RawConfigurationValues] and the ViewModel.
 */
class RawConfigurationTest {
    private val schema = RawConfigurationSchema.fromJson(
        SettingsSearchAsset.locate("app/src/main/assets/settings_schema.json").readText(),
    )
    private val fresh = RawConfigurationValues.of(DictationUiState())

    /** Preferences the raw configuration does not carry, and why. */
    private val unboundPreferences = mapOf(
        "raw_configuration_other_platform_settings" to "Other platforms' settings the raw editor keeps.",
        // As on the Mac, prompts and profiles are edited on their own pages, not in the raw document.
        "postProcessingSystemPrompt" to "Free-text prompt with its own Cleanup prompt editor in Settings.",
        "dictationProfiles" to "Profiles are structured records with their own editor.",
        "activeDictationProfileID" to "Follows the profiles, which the raw document does not carry.",
        // Consent is only ever given on its own screen, never by pasting a document.
        "analyticsConsent" to "Analytics opt-in is a consent choice.",
        "diagnosticsConsent" to "Crash-report consent is a consent choice.",
        // Not in the Android schema yet; binding them is tracked in #1700.
        "recordingSoundsEnabled" to "Recording sounds are edited in Settings only for now.",
        "recordingSoundProfile" to "Recording sounds are edited in Settings only for now.",
        "recordingSoundVolume" to "Recording sounds are edited in Settings only for now.",
        "silenceDetectionEnabled" to "Silence detection is edited in Settings only for now.",
        "silenceThreshold" to "Silence detection is edited in Settings only for now.",
        "silenceDuration" to "Silence detection is edited in Settings only for now.",
        "hasCompletedOnboarding" to "First-run state, reopened from Settings > Setup guide, not a preference.",
    )

    private fun validate(settings: String, current: Map<String, Any?> = fresh) =
        RawConfiguration.validate(
            schema,
            """{"schemaVersion": 1, "platform": "android", "settings": $settings}""",
            current,
        )

    @Test
    fun everyPreferenceHasAFieldAndEveryFieldABinding() {
        val preferences = SettingsSearchAsset
            .locate("app/src/main/java/com/justspeaktoit/android/settings/AppPreferences.kt").readText()
        val keys = Regex("""const val KEY_\w+ = "([^"]+)"""").findAll(preferences).map { it.groupValues[1] }.toSet()
        assertEquals(keys - unboundPreferences.keys, schema.keys.toSet())
        assertEquals(schema.keys.toSet(), fresh.keys)
    }

    @Test
    fun allowedValuesMatchTheAppsChoices() {
        assertEquals(RecognitionMode.entries.map { it.name }, schema.field("chosen_mode")?.allowedValues)
        assertEquals(Retention.entries.map { it.name }, schema.field("history_retention")?.allowedValues)
        assertEquals(CloudCatalog.transcriptionModels.map { it.catalogId }, schema.field("cloud_model")?.allowedValues)
        assertEquals(CloudCatalog.cleanupModels.map { it.selectionId }, schema.field("cleanup_model")?.allowedValues)
        assertEquals(DictationLanguages.all.map { it.id }, schema.field("preferredLocale")?.allowedValues)
    }

    @Test
    fun freshInstallEqualsTheSchemaDefaults() {
        assertEquals(schema.defaults, fresh)
    }

    @Test
    fun exportedDocumentValidatesWithoutChangesAndHasNoSecrets() {
        val values = fresh + ("personal_corrections" to RawConfigurationValues.corrections(
            listOf(CorrectionRule("Kubernetes", listOf("cube a netties", "kubernetis"))),
        ))
        val other = mapOf("postProcessingEnabled" to true)
        val document = RawConfiguration.document(schema, values, mapOf("openai.apiKey" to true), other)
        assertFalse(document.contains("sk-"))
        assertTrue(document.contains("\"isSet\" : true"))
        val report = RawConfiguration.validate(schema, document, values)
        assertEquals(emptyList<RawConfigurationIssue>(), report.errors)
        assertEquals(emptyMap<String, Any?>(), report.changes)
        assertEquals(other, report.otherPlatformSettings)
    }

    @Test
    fun reportsEveryProblemAndChangesNothingWhenInvalid() {
        val report = validate(
            """{"cleanup_enabled": "yes", "cloud_model": "deepgram/nova-3", "history_retention": "Year",
               "keepAudioOnCancel": false, "colour": "blue"}""",
        )
        assertEquals(
            listOf("settings.cleanup_enabled", "settings.cloud_model", "settings.colour", "settings.history_retention"),
            report.errors.map { it.path },
        )
        assertFalse(report.isValid)
    }

    @Test
    fun validDocumentReportsOnlyChangedValues() {
        val report = validate(
            """{"chosen_mode": "Cloud", "cleanup_enabled": false, "personal_corrections": {"Ada": "ada, adder"}}""",
        )
        assertTrue(report.isValid)
        val corrections = mapOf("Ada" to "ada, adder")
        assertEquals(mapOf("chosen_mode" to "Cloud", "personal_corrections" to corrections), report.changes)
        val rules = RawConfigurationValues.corrections(report.changes["personal_corrections"] as Map<*, *>, emptyList())
        assertEquals(listOf(CorrectionRule("Ada", listOf("ada", "adder"))), rules)
    }

    @Test
    fun rejectsSecretsNewerVersionsAndTrailingText() {
        val secret = RawConfiguration.validate(schema, """{"schemaVersion": 1, "apiKeys": {"openai": "sk-x"}}""", fresh)
        assertEquals(listOf("apiKeys.openai"), secret.errors.map { it.path })
        val newer = RawConfiguration.validate(schema, """{"schemaVersion": 99}""", fresh)
        assertEquals(listOf("schemaVersion"), newer.errors.map { it.path })
        assertFalse(RawConfiguration.validate(schema, """{"schemaVersion": 1} x""", fresh).isValid)
    }

    @Test
    fun anotherPlatformsDocumentWarnsAndKeepsItsSettings() {
        val report = RawConfiguration.validate(
            schema,
            """{"schemaVersion": 1, "platform": "macOS",
               "settings": {"postProcessingEnabled": true, "keepAudioOnCancel": false}}""",
            fresh,
        )
        assertTrue(report.isValid)
        assertEquals(listOf("platform", "settings.postProcessingEnabled"), report.warnings.map { it.path })
        assertEquals(mapOf("keepAudioOnCancel" to false), report.changes)
        assertEquals(mapOf("postProcessingEnabled" to true), report.otherPlatformSettings)
    }

    @Test
    fun correctionsKeepTheCurrentOrder() {
        val current = listOf(CorrectionRule("B", listOf("bee")), CorrectionRule("A", listOf("ay")))
        val rules = RawConfigurationValues.corrections(linkedMapOf("A" to "ay", "C" to "sea", "B" to "bee"), current)
        assertEquals(listOf("B", "A", "C"), rules.map { it.writeAs })
    }
}
