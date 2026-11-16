package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.local.LocalTranscriptionException
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.ProviderException

/**
 * Transcribes a recording kept in History. It only computes the updated entry; the caller writes it.
 * Success completes the entry and drops its audio unless recordings are kept; a failure keeps the
 * audio and records why, so the user can try again. A request the user released leaves the entry
 * unchanged. [transcribeLocal] does the same with a downloaded model and never sends the audio anywhere.
 */
internal class HistoryRetry(
    private val cloud: CloudService,
    private val secrets: SecretStore,
    private val capture: CloudCapture,
    private val io: CoroutineDispatcher,
    private val deadlineMs: Long,
    private val downloaded: DownloadedTranscription = DownloadedTranscription.Unavailable,
) {
    suspend fun transcribe(
        entry: HistoryEntry,
        model: CloudModel,
        languageTag: String,
        corrections: List<CorrectionRule> = emptyList(),
        /** Keeps the audio after a successful transcription, so it can still be played. */
        keepAudio: Boolean = false,
    ): HistoryEntry {
        val file = File(entry.audioPath ?: return entry)
        // A streaming model cannot transcribe a file; the audio stays for a retry with a batch model.
        if (model.live != null) return entry.copy(failure = DictationFailure.LiveOnlyModel.name)
        return try {
            if (!withContext(io) { file.isFile }) {
                // The audio is gone, so the entry can no longer be transcribed.
                entry.copy(status = HistoryStatus.Failed, failure = DictationFailure.Audio.name, audioPath = null)
            } else {
                val key = withContext(io) { secrets.read(model.provider.credentialId) }
                    ?: throw CloudException(DictationFailure.MissingKey, "No key")
                val vocabulary = corrections.map { it.writeAs }
                val text = capture.call(deadlineMs, model.provider) { call ->
                    cloud.transcribe(model, key, file, languageTag, call, vocabulary = vocabulary)
                }.trim().let { PersonalCorrections.apply(it, corrections) }
                completed(entry, model.catalogId, text, keepAudio)
            }
        } catch (e: RequestReleasedException) {
            // The user stopped it, so the entry stays as it was.
            entry
        } catch (e: CloudException) {
            entry.copy(failure = e.failure.name)
        } catch (e: GeneralSecurityException) {
            entry.copy(failure = DictationFailure.KeyUnavailable.name)
        } catch (e: ProviderException) {
            entry.copy(failure = DictationFailure.KeyUnavailable.name)
        } catch (e: IOException) {
            entry.copy(failure = DictationFailure.Audio.name)
        }
    }

    /** Transcribes [entry]'s recording with the downloaded model [modelId]; a failure keeps the audio. */
    suspend fun transcribeLocal(
        entry: HistoryEntry,
        modelId: String?,
        languageTag: String,
        corrections: List<CorrectionRule> = emptyList(),
        keepAudio: Boolean = false,
    ): HistoryEntry {
        val file = File(entry.audioPath ?: return entry)
        if (!withContext(io) { file.isFile }) {
            return entry.copy(status = HistoryStatus.Failed, failure = DictationFailure.Audio.name, audioPath = null)
        }
        return try {
            val text = downloaded.transcript(modelId, file, languageTag).trim()
                .let { PersonalCorrections.apply(it, corrections) }
            completed(entry.copy(mode = RecognitionMode.Downloaded.name), modelId, text, keepAudio)
        } catch (e: LocalTranscriptionException) {
            entry.copy(failure = e.failure.name)
        }
    }

    companion object {
        /**
         * A Downloaded recording is only ever transcribed on the phone. A recording recovered after the app
         * stopped has no model, so it follows the current mode.
         */
        fun usesDownloadedModel(entry: HistoryEntry, activeMode: RecognitionMode?): Boolean {
            if (entry.mode == RecognitionMode.Downloaded.name) return true
            val recovered = entry.model == null && entry.mode == RecognitionMode.Cloud.name
            return recovered && activeMode == RecognitionMode.Downloaded
        }
    }

    private fun completed(entry: HistoryEntry, modelId: String?, text: String, keepAudio: Boolean): HistoryEntry =
        if (text.isEmpty()) {
            entry.copy(failure = DictationFailure.NoSpeech.name)
        } else {
            entry.copy(
                status = HistoryStatus.Completed,
                model = modelId,
                text = text,
                failure = null,
                audioPath = entry.audioPath.takeIf { keepAudio },
            )
        }
}
