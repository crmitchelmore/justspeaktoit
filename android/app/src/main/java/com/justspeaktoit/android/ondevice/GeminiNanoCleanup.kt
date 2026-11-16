package com.justspeaktoit.android.ondevice

import com.justspeaktoit.android.cloud.CleanupPolicy
import com.justspeaktoit.android.cloud.GeneratedCloudCatalog
import kotlinx.coroutines.flow.Flow

/** ML Kit's `FeatureStatus` for Gemini Nano on this phone. */
enum class GeminiNanoStatus { Available, Downloadable, Downloading, Unavailable }

/** Why on-device cleanup kept the original transcript, or why Gemini Nano cannot be offered. */
enum class GeminiNanoFailure {
    /** The app was not the top foreground app; AICore refuses background use (BACKGROUND_USE_BLOCKED). */
    NotInForeground,

    /** AICore was serving another request (BUSY). */
    Busy,

    /** AICore's per-app battery quota ran out (PER_APP_BATTERY_USE_QUOTA_EXCEEDED). */
    QuotaExceeded,

    /** The request is over the input limit, or the reply would have been cut short. */
    TooLong,

    /** The model is still to download, or downloading. */
    NotDownloaded,

    /** The phone or its bootloader does not offer Gemini Nano, or AICore is not ready yet. */
    Unavailable,

    /** Android or AICore needs an update first (NEEDS_SYSTEM_UPDATE, AICORE_INCOMPATIBLE). */
    NeedsSystemUpdate,

    /** Not enough storage for the model download (NOT_ENOUGH_DISK_SPACE). */
    NotEnoughStorage,

    /** The model returned no text. */
    NoReply,

    /** Any other error. */
    Failed,
}

/** One Prompt API request: the cleanup instruction and the transcript data. */
data class GeminiNanoRequest(val systemInstruction: String?, val text: String)

/** The first candidate's text; [truncated] when it stopped at the output limit. */
data class GeminiNanoReply(val text: String?, val truncated: Boolean)

/** How a model download is going. */
sealed interface GeminiNanoDownload {
    data class Started(val bytesToDownload: Long) : GeminiNanoDownload

    data class Progress(val bytesDownloaded: Long) : GeminiNanoDownload

    data object Completed : GeminiNanoDownload

    data class Failed(val failure: GeminiNanoFailure) : GeminiNanoDownload
}

/** A Prompt API error, already mapped to what the user is told. */
class GeminiNanoException(val failure: GeminiNanoFailure, cause: Throwable? = null) :
    Exception(failure.name, cause)

/**
 * The ML Kit GenAI Prompt API as cleanup uses it ([MlKitGeminiNano]), so [GeminiNanoCleanup] is
 * tested with a fake. Every call may throw [GeminiNanoException].
 */
interface GeminiNanoModel {
    suspend fun status(): GeminiNanoStatus

    /** Whether this AICore build accepts a separate system instruction. */
    suspend fun supportsSystemInstruction(): Boolean

    suspend fun countTokens(request: GeminiNanoRequest): Int

    suspend fun generate(request: GeminiNanoRequest): GeminiNanoReply

    fun download(): Flow<GeminiNanoDownload>
}

/** How one on-device cleanup ended. */
sealed interface GeminiNanoResult {
    data class Cleaned(val text: String) : GeminiNanoResult

    /** An empty transcript: there is nothing to clean, so the model is not called. */
    data object Skipped : GeminiNanoResult

    data class Failed(val failure: GeminiNanoFailure) : GeminiNanoResult
}

/**
 * Cleans a transcript with Gemini Nano. The shared `TranscriptCleanupPolicy` prompt (or the user's own)
 * is the instruction, and the transcript goes separately as JSON data ([CleanupPolicy.userMessage]).
 * It runs only while [isTopApp] says the app is on screen, keeps the original text whenever anything
 * fails and never falls back to a cloud model.
 */
internal class GeminiNanoCleanup(
    private val model: GeminiNanoModel,
    private val isTopApp: () -> Boolean,
    private val inputTokenLimit: Int = GeneratedCloudCatalog.GEMINI_NANO_INPUT_TOKEN_LIMIT,
) {
    suspend fun clean(transcript: String, systemPrompt: String): GeminiNanoResult {
        if (transcript.isBlank()) return GeminiNanoResult.Skipped
        if (!isTopApp()) return GeminiNanoResult.Failed(GeminiNanoFailure.NotInForeground)
        return try {
            when (model.status()) {
                GeminiNanoStatus.Available -> generate(transcript, systemPrompt)
                GeminiNanoStatus.Downloadable, GeminiNanoStatus.Downloading ->
                    GeminiNanoResult.Failed(GeminiNanoFailure.NotDownloaded)
                GeminiNanoStatus.Unavailable -> GeminiNanoResult.Failed(GeminiNanoFailure.Unavailable)
            }
        } catch (e: GeminiNanoException) {
            GeminiNanoResult.Failed(e.failure)
        }
    }

    private suspend fun generate(transcript: String, systemPrompt: String): GeminiNanoResult {
        val request = request(transcript, systemPrompt, model.supportsSystemInstruction())
        if (model.countTokens(request) > inputTokenLimit) return GeminiNanoResult.Failed(GeminiNanoFailure.TooLong)
        // AICore refuses a request made after the user has left the app.
        if (!isTopApp()) return GeminiNanoResult.Failed(GeminiNanoFailure.NotInForeground)
        val reply = model.generate(request)
        val text = reply.text?.trim().orEmpty()
        return when {
            reply.truncated -> GeminiNanoResult.Failed(GeminiNanoFailure.TooLong)
            text.isEmpty() -> GeminiNanoResult.Failed(GeminiNanoFailure.NoReply)
            else -> GeminiNanoResult.Cleaned(text)
        }
    }

    companion object {
        /**
         * The instruction as a system instruction where AICore supports one; otherwise ahead of the
         * transcript data in one prompt, which still keeps the transcript as JSON data.
         */
        fun request(transcript: String, systemPrompt: String, systemInstruction: Boolean): GeminiNanoRequest {
            val data = CleanupPolicy.userMessage(transcript)
            return if (systemInstruction) {
                GeminiNanoRequest(systemPrompt, data)
            } else {
                GeminiNanoRequest(null, systemPrompt + "\n\n" + data)
            }
        }
    }
}
