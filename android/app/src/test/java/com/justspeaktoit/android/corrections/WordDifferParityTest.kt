package com.justspeaktoit.android.corrections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins cases SpeakCore's `WordDiffer` handles, so the Kotlin copy keeps the same rules. */
class WordDifferParityTest {
    @Test
    fun testFindChanges_similarNameIsAReplacement() {
        assertEquals(
            listOf(WordChange(WordChangeType.Replacement, "Suzy", "Susie")),
            WordDiffer.findChanges("Hi Suzy, how are you?", "Hi Susie, how are you?"),
        )
        assertEquals(
            listOf(WordChange(WordChangeType.Replacement, "teh", "the")),
            WordDiffer.findChanges("the teh sat", "the the sat"),
        )
    }

    @Test
    fun testFindChanges_oneWordBecomingTwoIsASplit() {
        assertEquals(
            listOf(WordChange(WordChangeType.Split, "gonna", "going to")),
            WordDiffer.findChanges("I'm gonna go home", "I'm going to go home"),
        )
    }

    @Test
    fun testFindChanges_twoWordsBecomingOneIsAMerge() {
        assertEquals(
            listOf(WordChange(WordChangeType.Merge, "can not", "cannot")),
            WordDiffer.findChanges("we can not stop", "we cannot stop"),
        )
    }

    @Test
    fun testFindChanges_rewritesAndDissimilarWordsAreIgnored() {
        assertTrue(
            WordDiffer.findChanges(
                "the quick brown fox jumps over the lazy dog today and tomorrow",
                "a completely different sentence with no overlap whatsoever at all here now",
            ).isEmpty(),
        )
        assertTrue(WordDiffer.findChanges("one", "one two three four five").isEmpty())
        assertTrue(WordDiffer.findChanges("the quick brown fox jumps", "the quick red fox jumps").isEmpty())
    }

    @Test
    fun testFindChanges_caseOnlyChangesAtTheEndsAreCommonText() {
        // Common ends compare words ignoring case, as in SpeakCore, so these are not changes.
        assertTrue(WordDiffer.findChanges("hello World", "Hello World").isEmpty())
        assertTrue(WordDiffer.findChanges("speak to it", "Speak to it").isEmpty())
    }

    @Test
    fun testIsLikelyCorrection_acceptsCaseOnlyReplacement() {
        assertTrue(WordChange(WordChangeType.Replacement, "speak", "Speak").isLikelyCorrection)
    }
}
