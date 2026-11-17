package com.justspeaktoit.android.ime

import com.justspeaktoit.android.settings.DictationProfile
import kotlin.math.ceil

/**
 * Which downloaded models (#1650, #1660) the keyboard may use, and for how long. The user is waiting in
 * another app's text field, so a downloaded model is used only when a conservative estimate of its finish
 * time fits inside [KeyboardPolicy.FINISH_TIMEOUT_MS], with headroom ([BUDGET_MS]). The rates below are
 * deliberately slow guesses for a mid-range phone, not measurements: they keep the large models out of the
 * keyboard until device timings (Docs/manual-checks.yml) justify more. Whatever the estimate says, the run
 * is still cut off at the finish bound and fails visibly.
 */
object KeyboardLocalModels {
    /** The share of [KeyboardPolicy.FINISH_TIMEOUT_MS] an estimate may use; the rest is headroom. */
    const val BUDGET_MS = KeyboardPolicy.FINISH_TIMEOUT_MS * 8 / 10

    /** The longest keyboard recording for a downloaded Whisper model, whatever its speed. */
    const val MAX_WHISPER_SECONDS = 120

    /** whisper.cpp encodes audio in fixed 30-second windows, so time grows per window, not per second. */
    const val WHISPER_WINDOW_SECONDS = 30

    /** Fixed cost of a run: creating the context, reading the recording and the JNI round trip. */
    private const val OVERHEAD_MS = 500L

    /** Reading the weights from storage into memory. */
    private const val LOAD_BYTES_PER_SECOND = 200_000_000L

    /** Hashing the weights before the first cleanup in each app process (SHA-256 on a phone). */
    private const val VERIFY_BYTES_PER_SECOND = 300_000_000L

    /** Whisper weights processed per second while transcribing one 30-second window. */
    private const val WHISPER_BYTES_PER_SECOND = 50_000_000L

    /** A llama.cpp model's prompt tokens per second is this divided by its size in bytes. */
    private const val PREFILL_BYTE_TOKENS_PER_SECOND = 60_000_000_000.0

    /** Its generated tokens per second is this divided by its size in bytes (memory bandwidth bound). */
    private const val DECODE_BYTE_TOKENS_PER_SECOND = 8_000_000_000.0

    /** Characters per token for English text and the JSON-wrapped prompt; low, so estimates run long. */
    private const val CHARS_PER_TOKEN = 3.0

    /** The chat template's own tokens, and the end-of-turn tokens of the reply. */
    private const val TEMPLATE_TOKENS = 32
    private const val REPLY_EXTRA_TOKENS = 16

    /**
     * The longest recording, in seconds, the keyboard allows with a downloaded Whisper model of [bytes],
     * in whole 30-second windows; 0 means the model is too slow for the keyboard at all.
     */
    fun whisperLimitSeconds(bytes: Long): Int {
        val fixed = OVERHEAD_MS + millis(bytes, LOAD_BYTES_PER_SECOND)
        val perWindow = millis(bytes, WHISPER_BYTES_PER_SECOND).coerceAtLeast(1)
        val windows = ((BUDGET_MS - fixed) / perWindow).coerceAtLeast(0)
        return (windows * WHISPER_WINDOW_SECONDS).toInt().coerceAtMost(MAX_WHISPER_SECONDS)
    }

    /**
     * The estimated time to clean up a transcript of [transcriptChars] characters with a cleanup model of
     * [bytes], given SYSTEM and USER messages of [promptChars] characters together (the reply is about as
     * long as the transcript). [verified] is false before the weights were hashed in this process, which
     * the first cleanup must do.
     */
    fun cleanupEstimateMs(bytes: Long, promptChars: Int, transcriptChars: Int, verified: Boolean): Long {
        val promptTokens = promptChars / CHARS_PER_TOKEN + TEMPLATE_TOKENS
        val replyTokens = transcriptChars / CHARS_PER_TOKEN + REPLY_EXTRA_TOKENS
        val prefillMs = promptTokens / (PREFILL_BYTE_TOKENS_PER_SECOND / bytes) * MILLIS
        val decodeMs = replyTokens / (DECODE_BYTE_TOKENS_PER_SECOND / bytes) * MILLIS
        val verifyMs = if (verified) 0L else millis(bytes, VERIFY_BYTES_PER_SECOND)
        return OVERHEAD_MS + verifyMs + millis(bytes, LOAD_BYTES_PER_SECOND) + ceil(prefillMs + decodeMs).toLong()
    }

    fun cleanupFits(bytes: Long, promptChars: Int, transcriptChars: Int, verified: Boolean): Boolean =
        cleanupEstimateMs(bytes, promptChars, transcriptChars, verified) <= BUDGET_MS

    /**
     * The downloaded cleanup model keyboard dictation uses, by the app's rule (`DictationUiState`): none
     * when cleanup is off for the session, or the profile names a cloud or Gemini Nano model (the keyboard
     * never sends dictation to a cleanup provider). A profile's own downloaded model ([catalog] holds the
     * cleanup catalogue's IDs) is used even when it is not on the phone, so it fails visibly; the user's own
     * is used only when [installed].
     */
    fun cleanupModelId(
        profile: DictationProfile?,
        cleanupEnabled: Boolean,
        userModelId: String?,
        catalog: Set<String>,
        installed: (String) -> Boolean,
    ): String? {
        if (!(profile?.cleanupEnabled ?: cleanupEnabled)) return null
        if (profile?.cleanupModel != null) return null
        profile?.downloadedCleanupModelId(catalog)?.let { return it }
        return userModelId?.takeIf { it in catalog && installed(it) }
    }

    private fun millis(bytes: Long, perSecond: Long): Long = bytes * 1_000 / perSecond

    private const val MILLIS = 1_000.0
}
