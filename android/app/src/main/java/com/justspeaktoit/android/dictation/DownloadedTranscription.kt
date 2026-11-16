package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.local.LocalTranscriber
import com.justspeaktoit.android.local.LocalTranscriptionException
import java.io.File

/**
 * Transcribes a recording with a downloaded Whisper model, for a session and for a History retry.
 * Nothing else is ever substituted: a model that is not downloaded is [DictationFailure.ModelMissing],
 * one that will not load is [DictationFailure.ModelCorrupt], and the caller keeps the recording.
 */
internal class DownloadedTranscription(
    /** The verified file for a catalogue ID, or null when that model is not downloaded. */
    private val installedFile: (String) -> File?,
    private val transcriber: LocalTranscriber,
) {
    /** The transcript; throws [LocalTranscriptionException]. Cancelling the call stops the model. */
    suspend fun transcript(modelId: String?, audio: File, languageTag: String?): String {
        if (!transcriber.available) {
            throw LocalTranscriptionException(DictationFailure.LocalModelFailed, "Runtime unavailable")
        }
        val model = modelId?.let(installedFile)
            ?: throw LocalTranscriptionException(DictationFailure.ModelMissing, "Model not downloaded")
        return transcriber.transcribe(model, audio, languageTag)
    }

    suspend fun transcribe(modelId: String?, audio: File, languageTag: String?): DictationEvent = try {
        DictationEvent.Final(transcript(modelId, audio, languageTag))
    } catch (e: LocalTranscriptionException) {
        DictationEvent.Error(e.failure)
    }

    companion object {
        /** No runtime: every request fails visibly. Used where downloaded models are not wired. */
        val Unavailable = DownloadedTranscription(
            installedFile = { null },
            transcriber = object : LocalTranscriber {
                override val available = false

                override suspend fun transcribe(model: File, audio: File, languageTag: String?): String =
                    throw LocalTranscriptionException(DictationFailure.LocalModelFailed, "Runtime unavailable")
            },
        )
    }
}
