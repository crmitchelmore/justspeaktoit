package com.justspeaktoit.android.corrections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PersonalCorrectionsTest {
    private val rules = listOf(
        CorrectionRule("Kubernetes", listOf("cooper netties", "cube a net ease")),
        CorrectionRule("C++", listOf("see plus plus")),
    )

    @Test
    fun testApply_replacesWholeAliasesIgnoringCase() {
        assertEquals(
            "Deploy Kubernetes in C++ then Kubernetes again.",
            PersonalCorrections.apply("Deploy Cooper Netties in see plus plus then cube a net ease again.", rules),
        )
    }

    @Test
    fun testApply_keepsTheSpellingsCaseWhenTheRecogniserAlreadyWritesTheWord() {
        assertEquals("I deploy to Kubernetes", PersonalCorrections.apply("I deploy to kubernetes", rules))
        assertEquals("Kubernetes, not kubernetesx", PersonalCorrections.apply("KUBERNETES, not kubernetesx", rules))
        assertEquals("iPhone", PersonalCorrections.apply("IPHONE", listOf(CorrectionRule("iPhone", emptyList()))))
    }

    @Test
    fun testApply_leavesPartialWordsAndRegexCharactersAlone() {
        val rule = listOf(CorrectionRule("$1 Ltd", listOf("acme")), CorrectionRule("x", listOf("a.c")))
        assertEquals("acmes and abc stay; $1 Ltd changes", PersonalCorrections.apply("acmes and abc stay; ACME changes", rule))
    }

    @Test
    fun testVocabularyPrompt_dedupesAndStaysWithinTheByteAndTermBudget() {
        assertEquals("Kubernetes, C++", PersonalCorrections.vocabularyPrompt(listOf(" Kubernetes ", "kubernetes", "", "C++")))
        assertEquals("one, two", PersonalCorrections.vocabularyPrompt(listOf("one", "two", "three"), maxBytes = 9))
        assertEquals("one", PersonalCorrections.vocabularyPrompt(listOf("one", "two"), maxTerms = 1))
        assertEquals("ok", PersonalCorrections.vocabularyPrompt(listOf("é".repeat(5), "ok"), maxBytes = 9))
        assertNull(PersonalCorrections.vocabularyPrompt(emptyList<String>()))
    }

    @Test
    fun testRule_splitsAliasesAndDropsTheSpellingItself() {
        assertEquals(
            CorrectionRule("Chris", listOf("kris", "Cris")),
            PersonalCorrections.rule(" Chris ", "kris, Cris\nKRIS, Chris,"),
        )
        assertNull(PersonalCorrections.rule("  ", "kris"))
    }

    @Test
    fun testEncodeDecode_roundTripsAndToleratesDamage() {
        assertEquals(rules, PersonalCorrections.decode(PersonalCorrections.encode(rules)))
        assertEquals(emptyList<CorrectionRule>(), PersonalCorrections.decode("not json"))
        assertEquals(emptyList<CorrectionRule>(), PersonalCorrections.decode(null))
        assertEquals(
            listOf(CorrectionRule("Ok", emptyList())),
            PersonalCorrections.decode("""[1, {"writeAs": ""}, {"writeAs": "Ok"}]"""),
        )
    }

    @Test
    fun testAccentedLetters_countAsPartOfTheWord() {
        val rules = listOf(CorrectionRule("CAF", listOf("caf")))
        assertEquals("café and CAF", PersonalCorrections.apply("café and caf", rules))
        assertEquals("naïve", PersonalCorrections.apply("naïve", listOf(CorrectionRule("X", listOf("na")))))
    }
}
