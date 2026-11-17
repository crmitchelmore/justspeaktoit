package com.justspeaktoit.android.local

import com.justspeaktoit.android.cloud.CleanupPolicy
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException

/** The JNI bridge to llama.cpp, in the same library as whisper.cpp (see Docs/android-on-device-models.md). */
internal object LlamaNative {
    /** False when the library is missing (a JVM unit test) or failed to load; local cleanup is then unavailable. */
    val loaded: Boolean by lazy {
        try {
            System.loadLibrary("jsti_local_models")
            true
        } catch (e: UnsatisfiedLinkError) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    /**
     * A session handle with no model yet, whose [timeoutMs] deadline starts now and covers both
     * [nativeLoad] and [nativeComplete].
     */
    @JvmStatic external fun nativeCreate(timeoutMs: Long): Long

    /**
     * Loads [path] into [handle]'s session. False when the file is not a decoder-only GGUF with a
     * vocabulary, or when the session was aborted or ran out of time while loading; [nativeLastError]
     * then says which. The chat template is checked by [nativeComplete]: there is no raw-prompt fallback.
     */
    @JvmStatic external fun nativeLoad(handle: Long, path: String): Boolean

    /**
     * Renders [system] and [user] (UTF-8) with the loaded model's chat template, then generates greedily.
     * Returns the UTF-8 reply, or null on failure, abort, the session's deadline or [maxTokens] without an
     * end of turn; never partial text. [nativeLastError] then says why.
     */
    @JvmStatic external fun nativeComplete(
        handle: Long,
        system: ByteArray,
        user: ByteArray,
        maxTokens: Int,
        threads: Int,
    ): ByteArray?

    /** The [LocalCleanupFailure] code of the last failed [nativeLoad] or [nativeComplete] on [handle]. */
    @JvmStatic external fun nativeLastError(handle: Long): Int

    /** Asks a running [nativeLoad] or [nativeComplete] on [handle] to stop; safe from any thread. */
    @JvmStatic external fun nativeAbort(handle: Long)

    @JvmStatic external fun nativeFree(handle: Long)
}

/** Why a downloaded-model cleanup did not apply. The original transcript is always kept. */
enum class LocalCleanupFailure(val code: Int) {
    RuntimeMissing(-1),
    ModelMissing(-2),
    ModelCorrupt(-3),
    Unknown(0),
    Aborted(1),
    NoChatTemplate(2),
    TooLong(3),
    Decode(4),
    NoEndOfTurn(5),
    InvalidOutput(6),
    Context(7),
    TimedOut(8),
    ;

    companion object {
        fun of(code: Int): LocalCleanupFailure = entries.firstOrNull { it.code == code } ?: Unknown
    }
}

class LocalCleanupException(val failure: LocalCleanupFailure, message: String) : Exception(message)

/** Rewrites a transcript with a downloaded model. Cancelling the call stops the model. */
interface LocalCleaner {
    /** Whether the runtime is present on this build and device. */
    val available: Boolean

    /**
     * The model's raw reply to [system] and [user]; throws [LocalCleanupException]. Never substitutes
     * another engine, and never returns partial output.
     */
    suspend fun complete(model: File, system: String, user: String): String
}

/**
 * The cleanup prompt a downloaded model receives, and the cleanup of what it returns, as the desktop
 * apps do (`LocalPostProcessingPrompt`). The SYSTEM message is the user's cleanup prompt (or the built-in
 * policy) plus a constraint that keeps small reasoning models from thinking aloud; the USER message is
 * the transcript wrapped as JSON data. The model's chat template turns the two into its prompt.
 */
object LocalCleanupPrompt {
    const val ENGINE_CONSTRAINT =
        "Local engine constraint: never enter thinking mode, emit <think> tags, include reasoning, or ask questions."

    fun system(customPrompt: String?): String = CleanupPolicy.systemPrompt(customPrompt) + "\n\n" + ENGINE_CONSTRAINT

    fun user(transcript: String): String = CleanupPolicy.userMessage(transcript)

    /** Nothing to clean: blank, or only Whisper's blank-audio marker. The model is not loaded for it. */
    fun isEmpty(transcript: String): Boolean = transcript.replace(BLANK_AUDIO, "").isBlank()

    /**
     * The usable text of a reply, trimmed; empty means no usable answer. Small models sometimes echo the
     * input's shape, so a reply that is exactly `{"transcript": "…"}` yields the string inside it. A reply
     * with `<think>` tags is rejected before this (see `DownloadedCleanup`), as on the desktop.
     */
    fun sanitize(reply: String): String {
        val text = reply.trim()
        return echoedTranscript(text) ?: text
    }

    private fun echoedTranscript(text: String): String? {
        if (!text.startsWith("{") || !text.endsWith("}")) return null
        val json = try {
            JSONObject(text)
        } catch (e: JSONException) {
            return null
        }
        if (json.length() != 1) return null
        return (json.opt("transcript") as? String)?.trim()
    }

    private const val BLANK_AUDIO = "[BLANK_AUDIO]"
}

/**
 * Checks a downloaded model's file against its pinned size and SHA-256 before it is loaded. The digest
 * is computed once per file version (path, size and modification time) in each app process, so the
 * first cleanup after a launch re-reads the weights and later ones only re-check the size.
 */
class PinnedWeightsVerifier(private val digest: (File) -> String = ModelDownloader::sha256) {
    private data class Version(val path: String, val bytes: Long, val modified: Long, val sha256: String)

    private val verified = mutableSetOf<Version>()
    private val lock = Any()

    fun verify(model: PinnedModel, file: File): Boolean {
        val bytes = file.length()
        if (!file.isFile || bytes != model.bytes) return false
        val version = Version(file.absolutePath, bytes, file.lastModified(), model.sha256)
        if (synchronized(lock) { version in verified }) return true
        val actual = try {
            digest(file)
        } catch (e: IOException) {
            return false
        }
        if (actual != model.sha256) return false
        synchronized(lock) { verified += version }
        return true
    }
}

/** llama.cpp through [LlamaNative], loading the model for each cleanup and freeing it after. */
class LlamaCppCleaner(
    private val io: CoroutineDispatcher,
    private val timeoutMs: Long,
    private val threads: Int = Runtime.getRuntime().availableProcessors().coerceIn(1, MAX_THREADS),
) : LocalCleaner {
    override val available: Boolean get() = LlamaNative.loaded

    /** One model in memory at a time. */
    private val running = Mutex()

    override suspend fun complete(model: File, system: String, user: String): String {
        if (!available) throw LocalCleanupException(LocalCleanupFailure.RuntimeMissing, "Runtime missing")
        return running.withLock { withContext(io) { run(model, system, user) } }
    }

    private suspend fun run(model: File, system: String, user: String): String {
        val handle = LlamaNative.nativeCreate(timeoutMs)
        if (handle == 0L) throw LocalCleanupException(LocalCleanupFailure.Context, "No session")
        try {
            return coroutineScope {
                // Cancelling this call aborts loading or generation; the watcher stops before the handle is freed.
                val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                    try {
                        awaitCancellation()
                    } finally {
                        LlamaNative.nativeAbort(handle)
                    }
                }
                try {
                    if (!LlamaNative.nativeLoad(handle, model.absolutePath)) {
                        val failure = LocalCleanupFailure.of(LlamaNative.nativeLastError(handle))
                            .takeIf { it == LocalCleanupFailure.Aborted || it == LocalCleanupFailure.TimedOut }
                            ?: LocalCleanupFailure.ModelCorrupt
                        throw LocalCleanupException(failure, "Model did not load")
                    }
                    val bytes = LlamaNative.nativeComplete(
                        handle,
                        system.toByteArray(Charsets.UTF_8),
                        user.toByteArray(Charsets.UTF_8),
                        MAX_OUTPUT_TOKENS,
                        threads,
                    ) ?: LlamaNative.nativeLastError(handle).let { code ->
                        throw LocalCleanupException(LocalCleanupFailure.of(code), "Cleanup failed ($code)")
                    }
                    String(bytes, Charsets.UTF_8)
                } finally {
                    withContext(NonCancellable) { watcher.cancelAndJoin() }
                }
            }
        } finally {
            LlamaNative.nativeFree(handle)
        }
    }

    private companion object {
        const val MAX_THREADS = 4

        /** As the desktop adapter; the native side also stops at the context window. */
        const val MAX_OUTPUT_TOKENS = 2_048
    }
}
