package com.justspeaktoit.android.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingGuideTest {
    @Test
    fun testFreshInstall_showsTheGuide() {
        assertTrue(OnboardingGuide.shouldShow(completed = null, hasChosenMode = false, micGranted = false))
    }

    @Test
    fun testInstallFromBeforeTheGuide_skipsIt() {
        assertFalse(OnboardingGuide.shouldShow(completed = null, hasChosenMode = true, micGranted = false))
        assertFalse(OnboardingGuide.shouldShow(completed = null, hasChosenMode = false, micGranted = true))
    }

    @Test
    fun testStoredDecision_winsOverInference() {
        assertFalse(OnboardingGuide.shouldShow(completed = true, hasChosenMode = false, micGranted = false))
        assertTrue(OnboardingGuide.shouldShow(completed = false, hasChosenMode = true, micGranted = true))
    }

    @Test
    fun testSteps_runFromWelcomeToDoneThroughTheTestDictation() {
        val walked = generateSequence(OnboardingStep.Welcome) { it.next }.toList()
        assertEquals(OnboardingStep.entries, walked)
        assertNull(OnboardingStep.Welcome.previous)
        assertEquals(OnboardingStep.Keyboard, OnboardingStep.TestDictation.previous)
        assertEquals(OnboardingStep.count, OnboardingStep.Done.position)
    }
}
