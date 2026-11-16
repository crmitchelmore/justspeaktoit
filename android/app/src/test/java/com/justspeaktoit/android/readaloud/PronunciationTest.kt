package com.justspeaktoit.android.readaloud

import com.justspeaktoit.android.ui.PronunciationEdits
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PronunciationTest {
    private fun entry(
        word: String,
        replacement: String?,
        caseSensitive: Boolean = false,
        isRegex: Boolean = false,
    ) = PronunciationEntry(
        id = PronunciationEntry.newId(),
        word = word,
        pronunciation = replacement ?: "x",
        replacement = replacement,
        isRegex = isRegex,
        caseSensitive = caseSensitive,
    )

    @Test
    fun testApply_replacesWholeWordsIgnoringCase() {
        val spoken = PronunciationDictionary.apply("The api and API, not apiary.", listOf(entry("API", "A P I")))

        assertEquals("The A P I and A P I, not apiary.", spoken)
    }

    @Test
    fun testApply_caseSensitiveReplacesOnlyExactText() {
        val spoken = PronunciationDictionary.apply("Go go GO", listOf(entry("go", "goh", caseSensitive = true)))

        assertEquals("Go goh GO", spoken)
    }

    @Test
    fun testApply_regexUsesTemplateAndRunsInOrder() {
        val entries = listOf(
            entry("""v(\d+)""", "version $1", isRegex = true),
            entry("version", "release"),
        )

        assertEquals("release 2 ships", PronunciationDictionary.apply("v2 ships", entries))
    }

    @Test
    fun testApply_skipsEntriesWithoutReplacementOrValidPattern() {
        val entries = listOf(entry("Kubernetes", null), entry("(", "paren", isRegex = true))

        assertEquals("Kubernetes (", PronunciationDictionary.apply("Kubernetes (", entries))
    }

    @Test
    fun testValidate_reportsEmptyDuplicateAndBadPattern() {
        assertNull(PronunciationDictionary.validate(listOf(entry("SQL", "sequel"))))
        assertEquals(PronunciationProblem.Empty, PronunciationDictionary.validate(listOf(entry(" ", "x"))))
        assertEquals(
            PronunciationProblem.Duplicate,
            PronunciationDictionary.validate(listOf(entry("SQL", "sequel"), entry("sql", "S Q L"))),
        )
        assertEquals(PronunciationProblem.InvalidPattern, PronunciationDictionary.validate(listOf(entry("[", "x", isRegex = true))))
    }

    @Test
    fun testJson_decodesSwiftEncodingAndRoundTrips() {
        // As Swift's JSONEncoder writes a PronunciationEntry: nil optionals are left out.
        val swift = """
            {"id":"6B1C1C9E-2D2C-4E36-9C1F-6F1B6C0E5A11","word":"nginx","pronunciation":"engine x",
             "replacement":"engine x","isRegex":false,"caseSensitive":false}
        """.trimIndent()

        val decoded = PronunciationEntry.fromJson(JSONObject(swift))!!

        assertEquals("nginx", decoded.word)
        assertNull(decoded.category)
        assertEquals(false, decoded.toJson().has("category"))
        assertEquals(listOf(decoded), PronunciationEntry.decodeList(PronunciationEntry.encodeList(listOf(decoded))))
    }

    @Test
    fun testJson_rejectsWhatSwiftWouldReject() {
        assertNull(PronunciationEntry.fromJson(JSONObject("""{"id":"not-a-uuid","word":"a","pronunciation":"b","isRegex":false,"caseSensitive":false}""")))
        assertNull(PronunciationEntry.fromJson(JSONObject("""{"id":"6B1C1C9E-2D2C-4E36-9C1F-6F1B6C0E5A11","word":"a","pronunciation":"b","isRegex":false}""")))
        assertNull(PronunciationEntry.decodeList("""[{"word":"a"}]"""))
        assertNull(PronunciationEntry.decodeList("not json"))
    }

    @Test
    fun testEdits_addReplacesSameWordKeepingIdentity() {
        val first = PronunciationEdits.add(emptyList(), " SQL ", "sequel", caseSensitive = false, regex = false)
        val updated = PronunciationEdits.add(first, "sql", "S Q L", caseSensitive = true, regex = false)

        assertEquals(1, updated.size)
        assertEquals(first.single().id, updated.single().id)
        assertEquals("S Q L", updated.single().replacement)
        assertEquals("S Q L", updated.single().pronunciation)
        assertEquals(true, updated.single().caseSensitive)
        assertNotEquals(first.single().id, PronunciationEdits.add(first, "API", "A P I", false, false).last().id)
    }
}
