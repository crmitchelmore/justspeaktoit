package com.justspeaktoit.android.ime

import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.settings.DictationProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardLocalModelsTest {
    private val system = LocalCleanupPrompt.system(null).length

    private fun prompt(transcript: String) = system + LocalCleanupPrompt.user(transcript).length

    private fun fits(bytes: Long, transcript: String, verified: Boolean = true) =
        KeyboardLocalModels.cleanupFits(bytes, prompt(transcript), transcript.length, verified)

    @Test
    fun testWhisperLimit_offersOnlyTheSmallModels_inWholeWindows() {
        assertEquals(120, KeyboardLocalModels.whisperLimitSeconds(TINY_BYTES))
        assertEquals(60, KeyboardLocalModels.whisperLimitSeconds(BASE_BYTES))
        assertEquals("Small is app-only", 0, KeyboardLocalModels.whisperLimitSeconds(SMALL_BYTES))
        assertEquals("Turbo is app-only", 0, KeyboardLocalModels.whisperLimitSeconds(TURBO_BYTES))
    }

    @Test
    fun testCleanupEstimate_fitsAShortDictationOnTheSmallModels_andNeverOnQwen17() {
        assertTrue(fits(SMOLLM2_BYTES, "send the report to sam by friday please"))
        assertTrue(fits(QWEN06_BYTES, "call me back"))
        assertFalse("a long dictation is too slow", fits(SMOLLM2_BYTES, "word ".repeat(200)))
        assertFalse(fits(QWEN17_BYTES, "ok"))
    }

    @Test
    fun testCleanupEstimate_countsHashingBeforeTheFirstRun() {
        val transcript = "send the report to sam by friday please"
        val chars = prompt(transcript)
        val verified = KeyboardLocalModels.cleanupEstimateMs(SMOLLM2_BYTES, chars, transcript.length, true)
        val unverified = KeyboardLocalModels.cleanupEstimateMs(SMOLLM2_BYTES, chars, transcript.length, false)
        assertTrue(unverified > verified)
    }

    @Test
    fun testCleanupModel_followsTheAppsRule_andNeverUsesACleanupProvider() {
        val installed = mutableSetOf(SMOLLM2)
        fun model(profile: DictationProfile?, enabled: Boolean = true, user: String? = SMOLLM2) =
            KeyboardLocalModels.cleanupModelId(profile, enabled, user, CATALOG, installed::contains)

        assertEquals(SMOLLM2, model(null))
        assertNull("cleanup off", model(null, enabled = false))
        assertNull("not downloaded", model(null, user = QWEN06))
        assertNull("not a downloaded model", model(null, user = "openai/gpt-5-mini"))

        val local = DictationProfile(id = "P", name = "Notes", cleanupModelId = QWEN06)
        assertEquals("the profile's model wins, even when missing", QWEN06, model(local))
        assertNull("the profile turns cleanup off", model(local.copy(cleanupEnabled = false)))
        assertEquals("the profile turns cleanup on", QWEN06, model(local.copy(cleanupEnabled = true), enabled = false))

        val cloud = DictationProfile(id = "P", name = "Work", cleanupModelId = "openai/gpt-5-mini")
        assertNull("a profile's cloud model is never replaced", model(cloud))
        assertEquals(SMOLLM2, model(DictationProfile(id = "P", name = "Plain")))
    }

    private companion object {
        const val SMOLLM2 = "local/post-processing/smollm2-360m-instruct-q4"
        const val QWEN06 = "local/post-processing/qwen3-0.6b-q4"
        val CATALOG = setOf(SMOLLM2, QWEN06, "local/post-processing/qwen3-1.7b-q4")

        // The pinned sizes in whisper_models.json and cleanup_models.json.
        const val TINY_BYTES = 77_691_713L
        const val BASE_BYTES = 147_951_465L
        const val SMALL_BYTES = 487_601_967L
        const val TURBO_BYTES = 574_041_195L
        const val SMOLLM2_BYTES = 270_590_880L
        const val QWEN06_BYTES = 396_705_472L
        const val QWEN17_BYTES = 1_107_409_472L
    }
}
