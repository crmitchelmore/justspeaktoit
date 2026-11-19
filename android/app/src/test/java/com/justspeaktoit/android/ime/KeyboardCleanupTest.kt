package com.justspeaktoit.android.ime

import com.justspeaktoit.android.dictation.DownloadedCleanup
import com.justspeaktoit.android.dictation.FakeCleaner
import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.local.PinnedModel
import com.justspeaktoit.android.local.llamaModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class KeyboardCleanupTest {
    @get:Rule val folder = TemporaryFolder()

    private val small: PinnedModel = llamaModel(id = MODEL)
    private val file by lazy { folder.newFile("model.gguf") }
    private var downloaded = true
    private val cleaner = FakeCleaner()

    private fun installed(id: String) = if (downloaded && id == MODEL) small to file else null

    private val keyboard by lazy {
        KeyboardCleanup(
            cleanup = DownloadedCleanup(::installed, { _, _ -> true }, cleaner, Dispatchers.IO, timeoutMs = 5_000),
            installed = ::installed,
            verified = { _, _ -> true },
            timeoutMs = 200,
        )
    }

    private fun clean(transcript: String = "hello there", prompt: String? = "Use British spelling.") =
        runBlocking { keyboard.clean(MODEL, transcript, prompt) }

    @Test
    fun testCleanup_usesThePromptAsSystemAndTheTranscriptAsUser() {
        cleaner.reply = { "Hello there." }

        assertEquals(KeyboardCleanupResult.Applied("Hello there."), clean())

        val call = cleaner.calls.single()
        assertEquals(LocalCleanupPrompt.system("Use British spelling."), call.system)
        assertEquals(LocalCleanupPrompt.user("hello there"), call.user)
    }

    @Test
    fun testEmptyInput_staysEmptyWithoutLoadingTheModel() {
        assertEquals(KeyboardCleanupResult.Empty, clean(transcript = " "))
        assertEquals(KeyboardCleanupResult.Empty, clean(transcript = "[BLANK_AUDIO]"))
        assertTrue(cleaner.calls.isEmpty())
    }

    @Test
    fun testRunThatWouldNotFit_isNotStarted() {
        val huge = llamaModel(id = MODEL, content = ByteArray(1))
        val tooBig = KeyboardCleanup(
            cleanup = DownloadedCleanup(::installed, { _, _ -> true }, cleaner, Dispatchers.IO, 5_000),
            installed = { huge.copy(bytes = 2_000_000_000L) to file },
            verified = { _, _ -> true },
        )

        assertEquals(KeyboardCleanupResult.TooLong, runBlocking { tooBig.clean(MODEL, "hello there", null) })
        assertTrue(cleaner.calls.isEmpty())
    }

    @Test
    fun testRunPastTheBound_isStopped_andKeepsTheOriginal() {
        cleaner.reply = { awaitCancellation() }

        assertEquals(KeyboardCleanupResult.TimedOut, clean())
    }

    @Test
    fun testMissingModel_failsVisibly_withoutTryingAnythingElse() {
        downloaded = false

        assertEquals(KeyboardCleanupResult.Failed, clean())
        assertTrue(cleaner.calls.isEmpty())
    }

    private companion object {
        const val MODEL = "local/post-processing/smollm2-360m-instruct-q4"
    }
}
