package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.local.LocalCleanupException
import com.justspeaktoit.android.local.LocalCleanupFailure
import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.local.PinnedModel
import com.justspeaktoit.android.local.pinnedModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DownloadedCleanupTest {
    @get:Rule val folder = TemporaryFolder()

    private val model: PinnedModel = pinnedModel(id = MODEL)
    private val file by lazy { folder.newFile("model.gguf") }
    private var downloaded = true
    private var verified = true
    private val cleaner = FakeCleaner()

    private val cleanup by lazy {
        DownloadedCleanup(
            installed = { id -> if (downloaded && id == MODEL) model to file else null },
            verify = { _, _ -> verified },
            cleaner = cleaner,
            io = Dispatchers.IO,
            timeoutMs = 200,
        )
    }

    private fun clean(transcript: String = "hello there", prompt: String? = "Use British spelling.") =
        runBlocking { cleanup.cleanup(MODEL, transcript, prompt) }

    @Test
    fun testCleanup_sendsThePromptAsSystemAndTheTranscriptAsUser_andAppliesTheReply() {
        cleaner.reply = { " Hello there. \n" }

        assertEquals(CleanupOutcome.Applied("Hello there."), clean())

        val call = cleaner.calls.single()
        assertEquals(file, call.model)
        assertEquals(LocalCleanupPrompt.system("Use British spelling."), call.system)
        assertEquals(LocalCleanupPrompt.user("hello there"), call.user)
    }

    @Test
    fun testEmptyInput_isReleasedWithoutLoadingTheModel() {
        assertEquals(CleanupOutcome.Released, clean(transcript = "  "))
        assertEquals(CleanupOutcome.Released, clean(transcript = "[BLANK_AUDIO]"))
        assertTrue(cleaner.calls.isEmpty())
    }

    @Test
    fun testEveryFailure_keepsTheOriginal_withoutTryingAnythingElse() {
        downloaded = false
        assertEquals("not downloaded", CleanupOutcome.Failed, clean())
        downloaded = true
        verified = false
        assertEquals("fails its pins", CleanupOutcome.Failed, clean())
        assertTrue("A model that fails its pins is never loaded", cleaner.calls.isEmpty())
        verified = true

        cleaner.available = false
        assertEquals("no runtime", CleanupOutcome.Failed, clean())
        cleaner.available = true

        cleaner.reply = { throw LocalCleanupException(LocalCleanupFailure.NoEndOfTurn, "ran out") }
        assertEquals("runtime error", CleanupOutcome.Failed, clean())
        cleaner.reply = { awaitCancellation() }
        assertEquals("over its deadline", CleanupOutcome.Failed, clean())
        cleaner.reply = { "<think>The user wants</think>Hello." }
        assertEquals("thinks aloud", CleanupOutcome.Failed, clean())
        cleaner.reply = { "\n " }
        assertEquals("blank reply", CleanupOutcome.Failed, clean())
    }

    @Test
    fun testAnEchoedTranscriptObject_isUnwrapped() {
        cleaner.reply = { """{"transcript": "Hello there."}""" }
        assertEquals(CleanupOutcome.Applied("Hello there."), clean())
    }

    private companion object {
        const val MODEL = "local/post-processing/qwen3-0.6b-q4"
    }
}
