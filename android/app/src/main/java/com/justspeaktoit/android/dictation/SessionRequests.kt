package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.CloudSharedDataKind
import com.justspeaktoit.android.cloud.CloudSharingBlockedException
import com.justspeaktoit.android.cloud.CloudSharingConsent
import com.justspeaktoit.android.cloud.CloudSharingProvider
import com.justspeaktoit.android.cloud.CloudSharingRequest
import com.justspeaktoit.android.cloud.RequestReleasedException
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.ondevice.GeminiNanoCleanup
import com.justspeaktoit.android.ondevice.GeminiNanoFailure
import com.justspeaktoit.android.ondevice.GeminiNanoResult
import com.justspeaktoit.android.security.SecretStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.GeneralSecurityException
import java.security.ProviderException

/** How an optional cleanup ended. [Released] means the user cancelled the request. */
internal sealed interface CleanupOutcome {
    data class Applied(val text: String) : CleanupOutcome

    data object Failed : CleanupOutcome

    data object Released : CleanupOutcome

    /** An empty transcript that on-device cleanup left empty without calling the model. */
    data object Skipped : CleanupOutcome

    /** Gemini Nano kept the original transcript; the reason is shown. No cloud model is tried instead. */
    data class OnDeviceFailed(val failure: GeminiNanoFailure) : CleanupOutcome

    /** The transcript was not sent. The app asks, and the original text stays. */
    data class NeedsConsent(val providerId: String) : CleanupOutcome
}

/**
 * A session's provider requests: the key is read off the main thread, and the request runs under its
 * deadline with a releasable hold ([CloudCapture.call]). Failures become the session's events; a key
 * the provider rejected or that could not be read is reported to [onKeyFailure] for the Errors filter.
 * A request the user released throws [RequestReleasedException], so the caller decides what a cancel
 * keeps. On-device cleanup goes to [onDevice] instead, which needs no key and never reaches the network.
 */
internal class SessionRequests(
    private val cloud: CloudService,
    private val secrets: SecretStore,
    private val capture: CloudCapture,
    private val io: CoroutineDispatcher,
    private val timings: DictationTimings,
    private val onDevice: GeminiNanoCleanup? = null,
    private val onKeyFailure: (CloudProvider, DictationFailure) -> Unit,
    /** Production passes the device store. The default allows, so tests of other behaviour still upload. */
    private val allowsSharing: (String, CloudSharedDataKind) -> Boolean = { _, _ -> true },
) {
    /**
     * Transcribes [file] with [model]. [missingKey] is the failure when no key is saved; [prepare]
     * runs after the key is read and before the upload (a shared file is copied in there) and returns
     * its format. Without it the file is the recorder's WAV. [vocabulary] is the personal dictionary's terms.
     * A live model cannot transcribe a file, and another model is never substituted for it.
     */
    suspend fun transcribe(
        model: CloudModel,
        file: File,
        languageTag: String,
        missingKey: DictationFailure,
        vocabulary: List<String> = emptyList(),
        prepare: suspend () -> SharedAudio.Format? = { null },
    ): DictationEvent = if (model.live != null) {
        DictationEvent.Error(DictationFailure.LiveOnlyModel)
    } else {
        upload(model, file, languageTag, missingKey, vocabulary, prepare)
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

    fun allows(providerId: String, kind: CloudSharedDataKind): Boolean = allowsSharing(providerId, kind)

    private suspend fun upload(
        model: CloudModel,
        file: File,
        languageTag: String,
        missingKey: DictationFailure,
        vocabulary: List<String>,
        prepare: suspend () -> SharedAudio.Format?,
    ): DictationEvent = try {
        if (!allowsSharing(model.provider.id, CloudSharedDataKind.Audio)) {
            throw CloudSharingBlockedException(
                model.provider.id,
                CloudSharedDataKind.Audio,
                CloudSharingConsent.blockedMessage(
                    CloudSharingRequest(
                        CloudSharingProvider(model.provider.id, model.provider.displayName, ""),
                        listOf(CloudSharedDataKind.Audio),
                        canUseOnDevice = true,
                    ),
                ),
            )
        }
        val key = withContext(io) { secrets.read(model.provider.credentialId) }
        if (key == null) {
            DictationEvent.Error(missingKey)
        } else {
            val format = prepare()
            DictationEvent.Final(
                capture.call(timings.transcribeMs, model.provider) { call ->
                    if (format == null) {
                        cloud.transcribe(model, key, file, languageTag, call, vocabulary = vocabulary)
                    } else {
                        cloud.transcribe(model, key, file, languageTag, call, format, vocabulary)
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
     * original text. Gemini Nano runs on the phone and reports why it kept the original.
     */
    suspend fun cleanup(model: CleanupModel, transcript: String, systemPrompt: String): CleanupOutcome {
        if (model.isOnDevice) return cleanupOnDevice(transcript, systemPrompt)
        val provider = model.cloudProvider
        if (!allowsSharing(provider.id, CloudSharedDataKind.Transcript)) {
            return CleanupOutcome.NeedsConsent(provider.id)
        }
        val cleaned = try {
            val key = withContext(io) { secrets.read(provider.credentialId) }
            key?.let {
                capture.call(timings.cleanupMs, provider) { call ->
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

    private suspend fun cleanupOnDevice(transcript: String, systemPrompt: String): CleanupOutcome {
        val engine = onDevice ?: return CleanupOutcome.OnDeviceFailed(GeminiNanoFailure.Unavailable)
        val result = withTimeoutOrNull(timings.cleanupMs) { engine.clean(transcript, systemPrompt) }
            ?: return CleanupOutcome.OnDeviceFailed(GeminiNanoFailure.Failed)
        return when (result) {
            is GeminiNanoResult.Cleaned -> CleanupOutcome.Applied(result.text)
            GeminiNanoResult.Skipped -> CleanupOutcome.Skipped
            is GeminiNanoResult.Failed -> CleanupOutcome.OnDeviceFailed(result.failure)
        }
    }

    /** Only a key the provider rejected, or one that could not be read, shows under Errors. */
    private fun noteKeyFailure(provider: CloudProvider, failure: DictationFailure) {
        if (failure == DictationFailure.InvalidKey || failure == DictationFailure.KeyUnavailable) {
            onKeyFailure(provider, failure)
        }
    }
}
