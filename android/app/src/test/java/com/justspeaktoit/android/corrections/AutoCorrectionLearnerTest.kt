package com.justspeaktoit.android.corrections

import com.justspeaktoit.android.dictation.MemoryPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoCorrectionLearnerTest {
    private val prefs = MemoryPrefs()
    private var now = 1_000L
    private var ids = 0
    private val learner = AutoCorrectionLearner(prefs, clock = { now }, newId = { "id${ids++}" })

    private fun editSuzy(app: String? = "com.example.notes") =
        learner.recordEdit("Hi Suzy, see you soon.", "Hi Susie, see you soon.", app)

    @Test
    fun testRecordEdit_countsUntilThresholdThenPromotesToACorrection() {
        prefs.correctionPromotionThreshold = 3
        assertTrue(editSuzy())
        now = 2_000L
        assertTrue(editSuzy("com.example.chat"))
        val pending = learner.pending().single()
        assertEquals("Suzy" to "Susie", pending.original to pending.corrected)
        assertEquals(2, pending.seenCount)
        assertEquals(1_000L, pending.firstSeenAt)
        assertEquals(2_000L, pending.lastSeenAt)
        assertEquals(setOf("com.example.notes", "com.example.chat"), pending.sourceApps)
        assertTrue(prefs.corrections.isEmpty())

        assertTrue(editSuzy())
        assertTrue(learner.pending().isEmpty())
        assertEquals(listOf(CorrectionRule("Susie", listOf("Suzy"))), prefs.corrections)
        // The correction applies to the next transcript, so nothing is learned twice.
        assertEquals("Hi Susie.", PersonalCorrections.apply("Hi Suzy.", prefs.corrections))
    }

    @Test
    fun testRecordEdit_ignoresRewritesAndUnchangedText() {
        assertFalse(learner.recordEdit("Hi Suzy.", "Hi Suzy.", null))
        assertFalse(learner.recordEdit("one", "one two three four five six seven eight", null))
        assertTrue(prefs.correctionCandidates.isEmpty())
    }

    @Test
    fun testPromotion_doesNotDuplicateAnExistingRule() {
        prefs.corrections = listOf(CorrectionRule("susie", listOf("suzy")), CorrectionRule("Kubernetes", emptyList()))
        editSuzy()
        editSuzy()
        assertEquals(
            listOf(CorrectionRule("susie", listOf("suzy")), CorrectionRule("Kubernetes", emptyList())),
            prefs.corrections,
        )
    }

    @Test
    fun testPromotion_addsTheOriginalToARuleWithTheSameSpelling() {
        prefs.corrections = listOf(CorrectionRule("Susie", listOf("Suzie")))
        editSuzy()
        editSuzy()
        assertEquals(listOf(CorrectionRule("Susie", listOf("Suzie", "Suzy"))), prefs.corrections)
    }

    @Test
    fun testAccept_promotesNowAndDismiss_hidesForGood() {
        prefs.correctionPromotionThreshold = 5
        editSuzy()
        learner.recordEdit("I'm gonna go", "I'm going to go", null)
        val (suzy, gonna) = learner.pending()

        assertTrue(learner.accept(suzy.id))
        assertEquals(listOf(CorrectionRule("Susie", listOf("Suzy"))), prefs.corrections)
        assertFalse(learner.accept(suzy.id))

        learner.dismiss(gonna.id)
        assertTrue(learner.pending().isEmpty())
        // A dismissed edit is not counted again, so it is never promoted.
        repeat(5) { learner.recordEdit("I'm gonna go", "I'm going to go", null) }
        assertTrue(learner.pending().isEmpty())
        assertEquals(1, prefs.corrections.size)

        learner.clear()
        assertTrue(prefs.correctionCandidates.isEmpty())
    }

    @Test
    fun testCandidates_surviveEncodingAndSkipDamage() {
        editSuzy()
        val encoded = AutoCorrectionCandidate.encode(prefs.correctionCandidates)
        assertEquals(prefs.correctionCandidates, AutoCorrectionCandidate.decode(encoded))
        assertTrue(AutoCorrectionCandidate.decode("not json").isEmpty())
        assertTrue(AutoCorrectionCandidate.decode("""[{"id":"x","original":"","corrected":"y"}]""").isEmpty())
    }
}
