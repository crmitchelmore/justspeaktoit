package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.File
import java.security.GeneralSecurityException
import java.security.ProviderException

/** How an optional cleanup ended. [Released] means the user cancelled the request. */
internal sealed interface CleanupOutcome {
    data class Applied(val text: String) : CleanupOutcome

    data object Failed : CleanupOutcome

    data object Released : CleanupOutcome
}

/**
 * A session's provider requests: the key is read off the main thread, and the request runs under its
 * deadline with a releasable hold ([CloudCapture.call]). Failures become the session's events; a key
 * the provider rejected or that could not be read is reported to [onKeyFailure] for the Errors filter.
 * A request the user released throws [RequestReleasedException], so the caller decides what a cancel
 * keeps.
 */
internal class SessionRequests(
    private val cloud: CloudService,
    private val secrets: SecretStore,
    private val capture: CloudCapture,
    private val io: CoroutineDispatcher,
    private val timings: DictationTimings,
    private val onKeyFailure: (CloudProvider, DictationFailure) -> Unit,
) {
    /**
     * Transcribes [file] with [model]. [missingKey] is the failure when no key is saved; [prepare]
     * runs after the key is read and before the upload (a shared file is copied in there) and returns
     * its format. Without it the file is the recorder's WAV. [prompt] is the vocabulary glossary.
     * A live model cannot transcribe a file, and another model is never substituted for it.
     */
    suspend fun transcribe(
        model: CloudModel,
        file: File,
        languageTag: String,
        missingKey: DictationFailure,
        prompt: String? = null,
        prepare: suspend () -> SharedAudio.Format? = { null },
    ): DictationEvent = if (model.live != null) {
        DictationEvent.Error(DictationFailure.LiveOnlyModel)
    } else {
        upload(model, file, languageTag, missingKey, prompt, prepare)
    }

    /**
     * Reads [provider]'s key for a live session off the main thread: the key, or the failure that ends
     * the session ([missingKey] when none is saved). The caller reports the failure to [liveFailed].
     */
    suspend fun liveKey(provider: CloudProvider, missingKey: DictationFailure): Pair<String?, DictationFailure?> = try {
        val key = withContext(io) { secrets.read(provider.credentialId) }
        if (key == null) null to missingKey else key to null
    } catch (e: GeneralSecurityException) {
        null to DictationFailure.KeyUnavailable
    } catch (e: ProviderException) {
        null to DictationFailure.KeyUnavailable
    }

    /** A live session ended with [failure]; a rejected key is reported like an upload's. */
    fun liveFailed(provider: CloudProvider, failure: DictationFailure) = noteKeyFailure(provider, failure)

    private suspend fun upload(
        model: CloudModel,
        file: File,
        languageTag: String,
        missingKey: DictationFailure,
        prompt: String?,
        prepare: suspend () -> SharedAudio.Format?,
    ): DictationEvent = try {
        val key = withContext(io) { secrets.read(model.provider.credentialId) }
        if (key == null) {
            DictationEvent.Error(missingKey)
        } else {
            val format = prepare()
            DictationEvent.Final(
                capture.call(timings.transcribeMs, model.provider) { call ->
                    if (format == null) {
                        cloud.transcribe(model, key, file, languageTag, call, prompt = prompt)
                    } else {
                        cloud.transcribe(model, key, file, languageTag, call, format, prompt)
                    }
                },
            )
        }
    } catch (e: CloudException) {
        noteKeyFailure(model.provider, e.failure)
        DictationEvent.Error(e.failure)
    } catch (e: GeneralSecurityException) {
        noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
        DictationEvent.Error(DictationFailure.KeyUnavailable)
    } catch (e: ProviderException) {
        noteKeyFailure(model.provider, DictationFailure.KeyUnavailable)
        DictationEvent.Error(DictationFailure.KeyUnavailable)
    }

    /**
     * Cleans up [transcript] with [systemPrompt]. Any failure, including a missing key, keeps the
     * original text.
     */
    suspend fun cleanup(model: CleanupModel, transcript: String, systemPrompt: String): CleanupOutcome {
        val cleaned = try {
            val key = withContext(io) { secrets.read(model.provider.credentialId) }
            key?.let {
                capture.call(timings.cleanupMs, model.provider) { call ->
                    cloud.cleanup(model, it, transcript, systemPrompt, call)
                }
            }
        } catch (e: RequestReleasedException) {
            return CleanupOutcome.Released
        } catch (e: CloudException) {
            null
        } catch (e: GeneralSecurityException) {
            null
        } catch (e: ProviderException) {
            null
        }
        return if (cleaned.isNullOrBlank()) CleanupOutcome.Failed else CleanupOutcome.Applied(cleaned)
    }

    /** Only a key the provider rejected, or one that could not be read, shows under Errors. */
    private fun noteKeyFailure(provider: CloudProvider, failure: DictationFailure) {
        if (failure == DictationFailure.InvalidKey || failure == DictationFailure.KeyUnavailable) {
            onKeyFailure(provider, failure)
        }
    }
}
