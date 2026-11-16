package com.justspeaktoit.android.local

import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.dictation.DictationFailure
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale

/** The JNI bridge to whisper.cpp, built from `src/main/cpp` (see Docs/android-on-device-models.md). */
internal object WhisperNative {
    /** False when the library is missing (a JVM unit test) or failed to load; the mode is then unavailable. */
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

    /** A context handle, or 0 when the file is not a model whisper.cpp can load. */
    @JvmStatic external fun nativeOpen(path: String): Long

    /** UTF-8 transcript bytes, or null when decoding failed or was aborted. */
    @JvmStatic external fun nativeTranscribe(handle: Long, samples: FloatArray, language: String, threads: Int): ByteArray?

    /** Asks a running [nativeTranscribe] on [handle] to stop; safe from any thread. */
    @JvmStatic external fun nativeAbort(handle: Long)

    @JvmStatic external fun nativeFree(handle: Long)
}

/** A downloaded-model transcription that could not finish; the recording is kept for a retry. */
class LocalTranscriptionException(val failure: DictationFailure, message: String) : Exception(message)

/** Transcribes a recording with a downloaded model. Cancelling the call stops the model. */
interface LocalTranscriber {
    /** Whether the runtime is present on this build and device. */
    val available: Boolean

    /** Throws [LocalTranscriptionException]; never substitutes another engine. */
    suspend fun transcribe(model: File, audio: File, languageTag: String?): String
}

/** whisper.cpp through [WhisperNative], loading the model for each transcription and freeing it after. */
class WhisperCppTranscriber(
    private val io: CoroutineDispatcher,
    private val threads: Int = Runtime.getRuntime().availableProcessors().coerceIn(1, MAX_THREADS),
) : LocalTranscriber {
    override val available: Boolean get() = WhisperNative.loaded

    override suspend fun transcribe(model: File, audio: File, languageTag: String?): String {
        if (!available) throw LocalTranscriptionException(DictationFailure.LocalModelFailed, "Runtime missing")
        val samples = withContext(io) { WhisperAudio.read(audio) }
        return withContext(io) {
            val handle = WhisperNative.nativeOpen(model.absolutePath)
            if (handle == 0L) throw LocalTranscriptionException(DictationFailure.ModelCorrupt, "Model did not load")
            try {
                coroutineScope {
                    // Cancelling this call aborts the decode; the watcher is stopped before the handle is freed.
                    val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                        try {
                            awaitCancellation()
                        } finally {
                            WhisperNative.nativeAbort(handle)
                        }
                    }
                    try {
                        val bytes = WhisperNative.nativeTranscribe(handle, samples, languageCode(languageTag), threads)
                            ?: throw LocalTranscriptionException(DictationFailure.LocalModelFailed, "Decode failed")
                        String(bytes, Charsets.UTF_8).trim()
                    } finally {
                        withContext(NonCancellable) { watcher.cancelAndJoin() }
                    }
                }
            } finally {
                WhisperNative.nativeFree(handle)
            }
        }
    }

    private companion object {
        const val MAX_THREADS = 4
    }
}

/** The language whisper.cpp should assume: a primary ISO 639-1 code, or empty to detect it. */
internal fun languageCode(languageTag: String?): String {
    if (languageTag.isNullOrBlank()) return ""
    return Locale.forLanguageTag(languageTag).language.lowercase(Locale.ROOT)
}

/** Reads the recorder's 16 kHz mono PCM16 WAV as the float samples whisper.cpp takes. */
internal object WhisperAudio {
    /** The recorder stops at ten minutes; a little over that allows for a History retry of a recovered file. */
    const val MAX_SECONDS = 620L

    fun read(file: File): FloatArray {
        val size = try {
            file.length()
        } catch (e: SecurityException) {
            throw LocalTranscriptionException(DictationFailure.Audio, "Unreadable recording")
        }
        if (!file.isFile || size < WavFormat.HEADER_BYTES) {
            throw LocalTranscriptionException(DictationFailure.Audio, "Missing recording")
        }
        val payload = size - WavFormat.HEADER_BYTES
        if (payload > MAX_SECONDS * WavFormat.BYTES_PER_SECOND) {
            throw LocalTranscriptionException(DictationFailure.AudioTooLarge, "Recording too long")
        }
        if (payload == 0L) throw LocalTranscriptionException(DictationFailure.NoSpeech, "Empty recording")
        val bytes = try {
            file.readBytes()
        } catch (e: IOException) {
            throw LocalTranscriptionException(DictationFailure.Audio, "Unreadable recording")
        }
        if (bytes.size.toLong() != size || payload % 2 != 0L ||
            !bytes.copyOfRange(0, WavFormat.HEADER_BYTES).contentEquals(WavFormat.header(payload))
        ) {
            throw LocalTranscriptionException(DictationFailure.UnsupportedAudio, "Needs a 16 kHz mono 16-bit WAV")
        }
        val pcm = ByteBuffer.wrap(bytes, WavFormat.HEADER_BYTES, payload.toInt()).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray((payload / 2).toInt()) { pcm.short / PCM_SCALE }
    }

    private const val PCM_SCALE = 32_768f
}
