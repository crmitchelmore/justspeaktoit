package com.justspeaktoit.android.ime

import com.justspeaktoit.android.dictation.CleanupOutcome
import com.justspeaktoit.android.dictation.DownloadedCleanup
import com.justspeaktoit.android.local.LocalCleanupPrompt
import com.justspeaktoit.android.local.PinnedModel
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/** What keyboard cleanup did with a transcript. Anything but [Applied] keeps what was said. */
internal sealed interface KeyboardCleanupResult {
    data class Applied(val text: String) : KeyboardCleanupResult

    /** Nothing to clean, so the model was not loaded. */
    data object Empty : KeyboardCleanupResult

    /** The estimate does not fit the keyboard's finish bound, so the model was not loaded. */
    data object TooLong : KeyboardCleanupResult

    /** It ran past the keyboard's finish bound and was stopped. */
    data object TimedOut : KeyboardCleanupResult

    /** Missing, failed its pinned check, did not load or gave nothing usable. */
    data object Failed : KeyboardCleanupResult
}

/**
 * Cleans up keyboard dictation with a downloaded llama.cpp model (#1660), as the app does, but bounded
 * by the keyboard's finish time: a run whose estimate ([KeyboardLocalModels.cleanupFits]) does not fit is
 * not started, and one still running at [timeoutMs] is stopped. Either way the original stays; no cloud
 * or other model is tried. [cleanup]'s own deadline must be longer than [timeoutMs], so the keyboard's
 * bound is the one that ends a slow run.
 */
internal class KeyboardCleanup(
    private val cleanup: DownloadedCleanup,
    /** The model and its file for a catalogue ID, or null when that model is not downloaded. */
    private val installed: (String) -> Pair<PinnedModel, File>?,
    /** Whether the weights were already hashed in this process. */
    private val verified: (PinnedModel, File) -> Boolean,
    private val timeoutMs: Long = KeyboardPolicy.FINISH_TIMEOUT_MS,
) {
    /** Whether [transcript] would be cleaned up by [modelId] in time; a missing model runs, to fail visibly. */
    fun fits(modelId: String, transcript: String, customPrompt: String?): Boolean {
        val (model, file) = installed(modelId) ?: return true
        return KeyboardLocalModels.cleanupFits(
            bytes = model.bytes,
            promptChars = LocalCleanupPrompt.system(customPrompt).length + LocalCleanupPrompt.user(transcript).length,
            transcriptChars = transcript.length,
            verified = verified(model, file),
        )
    }

    suspend fun clean(modelId: String, transcript: String, customPrompt: String?): KeyboardCleanupResult {
        if (LocalCleanupPrompt.isEmpty(transcript)) return KeyboardCleanupResult.Empty
        if (!fits(modelId, transcript, customPrompt)) return KeyboardCleanupResult.TooLong
        val outcome = withTimeoutOrNull(timeoutMs) { cleanup.cleanup(modelId, transcript, customPrompt) }
            ?: return KeyboardCleanupResult.TimedOut
        return when (outcome) {
            is CleanupOutcome.Applied -> KeyboardCleanupResult.Applied(outcome.text)
            CleanupOutcome.Released -> KeyboardCleanupResult.Empty
            else -> KeyboardCleanupResult.Failed
        }
    }
}
