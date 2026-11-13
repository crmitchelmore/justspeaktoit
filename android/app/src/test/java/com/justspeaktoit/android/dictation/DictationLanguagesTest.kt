package com.justspeaktoit.android.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationLanguagesTest {
    @Test
    fun testCatalogue_startsWithAutomatic() {
        assertTrue(DictationLanguages.all.first().isAutomatic)
        assertTrue(DictationLanguages.all.any { it.id == "en_GB" })
    }

    @Test
    fun testNormalized_treatsUnknownAndMissingIdsAsAutomatic() {
        assertEquals("en_GB", DictationLanguages.normalized(" en_GB "))
        assertEquals(DictationLanguages.AUTOMATIC, DictationLanguages.normalized(null))
        assertEquals(DictationLanguages.AUTOMATIC, DictationLanguages.normalized("xx_YY"))
    }

    @Test
    fun testLanguageTag_isThePhoneLanguageForAutomaticAndBcp47Otherwise() {
        assertEquals("de-AT", DictationLanguages.languageTag(null) { "de-AT" })
        assertEquals("de-AT", DictationLanguages.languageTag("retired") { "de-AT" })
        assertEquals("fr-FR", DictationLanguages.languageTag("fr_FR") { "de-AT" })
    }
}
