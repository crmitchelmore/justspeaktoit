package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.ProviderException

/**
 * Transcribes a cancelled recording kept in History. It only computes the updated entry; the caller
 * writes it. Success completes the entry and drops its audio; a failure keeps the audio and records
 * why, so the user can try again. A request the user released leaves the entry unchanged.
 */
internal class HistoryRetry(
    private val cloud: CloudService,
    private val secrets: SecretStore,
    private val capture: CloudCapture,
    private val io: CoroutineDispatcher,
    private val deadlineMs: Long,
) {
    suspend fun transcribe(
        entry: HistoryEntry,
        model: CloudModel,
        languageTag: String,
        corrections: List<CorrectionRule> = emptyList(),
    ): HistoryEntry {
        val file = File(entry.audioPath ?: return entry)
        return try {
            if (!withContext(io) { file.isFile }) {
                // The audio is gone, so the entry can no longer be transcribed.
                entry.copy(status = HistoryStatus.Failed, failure = DictationFailure.Audio.name, audioPath = null)
            } else {
                val key = withContext(io) { secrets.read(model.provider.credentialId) }
                    ?: throw CloudException(DictationFailure.MissingKey, "No key")
                val prompt = PersonalCorrections.vocabularyPrompt(corrections)
                val text = capture.call(deadlineMs, model.provider) { call ->
                    cloud.transcribe(model, key, file, languageTag, call, prompt = prompt)
                }.trim().let { PersonalCorrections.apply(it, corrections) }
                if (text.isEmpty()) {
                    entry.copy(failure = DictationFailure.NoSpeech.name)
                } else {
                    entry.copy(
                        status = HistoryStatus.Completed,
                        model = model.catalogId,
                        text = text,
                        failure = null,
                        audioPath = null,
                    )
                }
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
}
