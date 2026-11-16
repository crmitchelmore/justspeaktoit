package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.WavFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SilenceAutoStopTest {
    @Test
    fun testMonitor_firesOnceAfterContinuousQuietIncludingTheStart() {
        val monitor = SilenceMonitor(threshold = 0.05, durationSeconds = 2.0)
        assertFalse(monitor.observe(0.01, 0.1))
        assertFalse(monitor.observe(0.01, 2.0))
        assertTrue(monitor.observe(0.01, 2.1))
        assertFalse(monitor.observe(0.01, 9.0))
    }

    @Test
    fun testMonitor_speechRestartsTheSilence() {
        val monitor = SilenceMonitor(threshold = 0.05, durationSeconds = 1.0)
        assertFalse(monitor.observe(0.01, 0.1))
        assertFalse(monitor.observe(0.05, 1.0))
        assertFalse(monitor.observe(0.01, 1.5))
        assertFalse(monitor.observe(0.01, 2.4))
        assertTrue(monitor.observe(0.01, 2.5))
    }

    @Test
    fun testMonitor_pausedLevelsNeitherAdvanceNorResetTheSilence() {
        val monitor = SilenceMonitor(threshold = 0.05, durationSeconds = 1.0)
        assertFalse(monitor.observe(0.01, 0.1))
        assertFalse(monitor.observe(Double.NaN, 0.6))
        assertFalse(monitor.observe(Double.NaN, 0.6))
        assertTrue(monitor.observe(0.01, 1.1))
    }

    @Test
    fun testSettings_clampToTheSharedRanges() {
        assertEquals(SilenceSettings(true, 0.01, 0.5), SilenceSettings.of(true, 0.0, 0.1))
        assertEquals(SilenceSettings(false, 0.2, 5.0), SilenceSettings.of(false, 1.0, 60.0))
        assertEquals(SilenceSettings(), SilenceSettings.of(false, Double.NaN, Double.NaN))
    }

    @Test
    fun testNormalizedLevel_matchesSpeakCoreScale() {
        assertEquals(0.0, WavFormat.normalizedLevel(ShortArray(1_600), 1_600), 0.0)
        assertEquals(1.0, WavFormat.normalizedLevel(ShortArray(1_600) { Short.MIN_VALUE }, 1_600), 1e-9)
        // A constant -40 dBFS signal: (0.7 * -40 + 0.3 * -40 + 60) / 60.
        val quiet = ShortArray(1_600) { 328 }
        assertEquals(1.0 / 3.0, WavFormat.normalizedLevel(quiet, quiet.size), 0.001)
        assertEquals(0.0, WavFormat.normalizedLevel(quiet, 0), 0.0)
    }
}
