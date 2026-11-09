package com.justspeaktoit.android.settings

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ranking parity with SpeakCore's `SettingsSearchIndex`, over the exported catalogue. */
class SettingsSearchTest {
    private val index = SettingsSearchIndex.fromCatalogueJson(SettingsSearchAsset.read())

    @Test
    fun exactTitleAndPrefixRankFirst() {
        assertEquals("android.cleanup", index.search("Clean up transcripts").first().entry.id)
        assertEquals("android.cloudModel", index.search("cloud trans").first().entry.id)
    }

    @Test
    fun keywordsSynonymsAndInflectionsFindIntent() {
        assertEquals("android.keepAudio", index.search("keep audio").first().entry.id)
        assertEquals("android.keepAudio", index.search("discard recording").first().entry.id)
        assertEquals("android.keepAudio", index.search("cancelled").first().entry.id)
        assertTrue(index.search("polish").any { it.entry.id == "android.cleanup" })
        assertTrue(index.search("token").any { it.entry.id == "android.apiKeys" })
    }

    @Test
    fun runtimeEntriesCoverModelsAndKeys() {
        assertEquals("${SettingsSearchIndex.KEY_PREFIX}openai", index.search("OpenAI API key").first().entry.id)
        assertTrue(index.search("groq").any { it.entry.id.startsWith(SettingsSearchIndex.MODEL_PREFIX) })
    }

    @Test
    fun toleratesTyposAndRejectsNonsense() {
        assertEquals("android.cleanup", index.search("trasncripts clean").first().entry.id)
        assertTrue(index.search("zzqxv").isEmpty())
        assertTrue(index.search("   ").isEmpty())
    }

    @Test
    fun matchedKeywordIsReportedOnlyWhenTheTitleDidNotMatch() {
        assertNull(index.search("Clean up transcripts").first().matchedKeyword)
        assertEquals("discard", index.search("discard").first().matchedKeyword)
    }

    @Test
    fun completionsExtendTypedText() {
        assertTrue(index.completions("clea").contains("Clean up transcripts"))
        assertTrue(index.completions("").isEmpty())
    }

    @Test
    fun recentsDedupeAndCap() {
        var recents = emptyList<String>()
        for (id in listOf("a1", "b2", "a1", "c3")) recents = SettingsSearchRecents.recording(id, recents, limit = 2)
        assertEquals(listOf("c3", "a1"), recents)
    }

    @Test
    fun editDistance() {
        assertTrue(SettingsSearchIndex.isWithin(1, "colour", "color"))
        assertFalse(SettingsSearchIndex.isWithin(1, "colour", "clr"))
    }
}

/** Reads the committed catalogue asset (generated from SpeakCore). */
object SettingsSearchAsset {
    fun read(): String = locate("app/src/main/assets/settings_search.json").readText()

    fun locate(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            for (candidate in listOf(File(dir, relative), File(dir, "android/$relative"), File(dir, relative.removePrefix("app/")))) {
                if (candidate.isFile) return candidate
            }
            dir = dir.parentFile
        }
        error("$relative not found above ${File("").absolutePath}")
    }
}
