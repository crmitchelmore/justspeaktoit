package com.justspeaktoit.android.settings

import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fails when a Settings section or persisted preference is added without a settings search
 * entry. Add it to `Sources/SpeakCore/SettingsSearch/SettingsSearchCatalog+Android.swift`, then
 * regenerate the asset (see Docs/settings-search.md).
 */
class SettingsSearchCoverageTest {
    private val catalogue = JSONObject(SettingsSearchAsset.read()).getJSONArray("entries")
    private val titles = (0 until catalogue.length()).map { catalogue.getJSONObject(it).getString("title") }.toSet()
    private val settingKeys = (0 until catalogue.length()).flatMap { index ->
        val keys = catalogue.getJSONObject(index).getJSONArray("settingKeys")
        (0 until keys.length()).map(keys::getString)
    }.toSet()

    /** Preferences set outside the Settings screen, and where. */
    private val unindexedPreferences = mapOf(
        "history_retention" to "Chosen on the History screen.",
        "chosen_mode" to "Chosen on the Dictation screen.",
        "raw_configuration_other_platform_settings" to "Other platforms' settings the raw editor keeps.",
    )

    @Test
    fun everySettingsHeadingIsIndexed() {
        val screen = SettingsSearchAsset.locate("app/src/main/java/com/justspeaktoit/android/ui/SettingsScreen.kt").readText()
        val strings = SettingsSearchAsset.locate("app/src/main/res/values/strings.xml").readText()
        val headings = Regex("""R\.string\.(settings_\w+_title)""").findAll(screen).map { it.groupValues[1] }
            .filter { it != "settings_title" }
            .toSet()
        assertTrue("SettingsScreen has no section headings", headings.isNotEmpty())
        val missing = headings.mapNotNull { name ->
            val value = Regex("""<string name="$name">([^<]*)</string>""").find(strings)?.groupValues?.get(1)
                ?.replace("\\'", "'")
            if (value == null || value !in titles) "$name ($value)" else null
        }
        assertTrue("Add Android settings search entries for: $missing", missing.isEmpty())
    }

    @Test
    fun everyPreferenceIsIndexed() {
        val preferences = SettingsSearchAsset
            .locate("app/src/main/java/com/justspeaktoit/android/settings/AppPreferences.kt").readText()
        val keys = Regex("""const val KEY_\w+ = "([^"]+)"""").findAll(preferences).map { it.groupValues[1] }.toList()
        assertTrue("AppPreferences has no keys", keys.isNotEmpty())
        val missing = keys.filter { it !in settingKeys && it !in unindexedPreferences }
        assertTrue("Index these preferences in an Android settings search entry: $missing", missing.isEmpty())
    }
}
