package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.local.LocalCleaner
import com.justspeaktoit.android.local.LocalCleanupException
import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.local.PinnedModel
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/**
 * Cleans up a transcript with a downloaded model (llama.cpp), as the desktop apps do with their local
 * models. The SYSTEM message is the user's cleanup prompt (or the built-in one) and the USER message is
 * the transcript; the model's chat template joins them.
 *
 * Nothing else is ever substituted: a model that is not downloaded, fails its pinned size and SHA-256
 * check, does not load, runs past [timeoutMs] or returns nothing usable is [CleanupOutcome.Failed], and
 * the caller keeps the original transcript. There is no cloud or rules fallback. Empty input is
 * [CleanupOutcome.Released] without loading the model.
 */
internal class DownloadedCleanup(
    /** The model and its file for a catalogue ID, or null when that model is not downloaded. */
    private val installed: (String) -> Pair<PinnedModel, File>?,
    /** Checks the file against the model's pinned size and SHA-256; runs on [io]. */
    private val verify: (PinnedModel, File) -> Boolean,
    private val cleaner: LocalCleaner,
    private val io: CoroutineDispatcher,
    /** Bounds loading and generation together; the runtime also stops itself at this deadline. */
    private val timeoutMs: Long,
) {
    val available: Boolean get() = cleaner.available

    /** Whether [modelId] is downloaded; its weights are verified when it is used. */
    fun isInstalled(modelId: String): Boolean = installed(modelId) != null

    suspend fun cleanup(modelId: String, transcript: String, customPrompt: String?): CleanupOutcome {
        if (LocalCleanupPrompt.isEmpty(transcript)) return CleanupOutcome.Released
        if (!cleaner.available) return CleanupOutcome.Failed
        val (model, file) = installed(modelId) ?: return CleanupOutcome.Failed
        // Interruptible, so a caller's own deadline (the keyboard's) also stops hashing the weights.
        if (!runInterruptible(io) { verify(model, file) }) return CleanupOutcome.Failed
        val reply = try {
            withTimeoutOrNull(timeoutMs) {
                cleaner.complete(file, LocalCleanupPrompt.system(customPrompt), LocalCleanupPrompt.user(transcript))
            }
        } catch (e: LocalCleanupException) {
            null
        } ?: return CleanupOutcome.Failed
        // As on the desktop, a reply that thinks aloud is rejected rather than trimmed into a transcript.
        if (reply.contains(THINK_OPEN, ignoreCase = true) || reply.contains(THINK_CLOSE, ignoreCase = true)) {
            return CleanupOutcome.Failed
        }
        val cleaned = LocalCleanupPrompt.sanitize(reply)
        return if (cleaned.isBlank()) CleanupOutcome.Failed else CleanupOutcome.Applied(cleaned)
    }

    companion object {
        private const val THINK_OPEN = "<think"
        private const val THINK_CLOSE = "</think>"

        /** No runtime: a selected downloaded model fails visibly. Used where downloaded models are not wired. */
        val Unavailable = DownloadedCleanup(
            installed = { null },
            verify = { _, _ -> false },
            cleaner = object : LocalCleaner {
                override val available = false

                override suspend fun complete(model: File, system: String, user: String): String =
                    error("Runtime unavailable")
            },
            io = Dispatchers.Unconfined,
            timeoutMs = 0,
        )
    }
}
