package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudSharedDataKind
import com.justspeaktoit.android.cloud.CloudSharingConsent
import com.justspeaktoit.android.cloud.CloudSharingRequest

/** A send waiting for the user's consent (#1805). Allowing runs it; nothing was recorded or sent before. */
sealed interface PendingCloudSend {
    /** A new recording, hands-free listening included. */
    data object Recording : PendingCloudSend

    /** Audio another app shared; it stays with that app until the user allows the upload. */
    data class SharedAudio(val offer: SharedAudioOffer) : PendingCloudSend

    /** A recording kept in History, which stays there until the user allows the upload. */
    data class HistoryEntry(val id: String) : PendingCloudSend
}

/** The providers a send needs consent for, and the send to run once the user allows it. */
data class CloudSharingPrompt(val requests: List<CloudSharingRequest>, val pending: PendingCloudSend) {
    /** Only a new recording can use an on-device recogniser instead; a saved file needs a provider. */
    val offersOnDevice: Boolean get() = pending == PendingCloudSend.Recording
}

/**
 * What a session's sends would give each provider: its audio to the Cloud model's provider when
 * [audioToCloud], and the transcript to a cloud cleanup model when cleanup runs in the cloud.
 */
internal fun DictationUiState.cloudSharingRequests(audioToCloud: Boolean): List<CloudSharingRequest> =
    CloudSharingConsent.merged(
        buildList {
            if (audioToCloud) add(CloudSharingConsent.request(sessionCloudModel.provider, CloudSharedDataKind.Audio))
            if (cleanupGoesToCloud) {
                add(CloudSharingConsent.request(sessionCleanupModel.cloudProvider, CloudSharedDataKind.TranscriptText))
            }
        },
    )

/** Cleanup is on, has a key, and runs on neither Gemini Nano nor a downloaded model. */
private val DictationUiState.cleanupGoesToCloud: Boolean
    get() = cleanupReady && profileLocalCleanupModelId == null && sessionLocalCleanupModelId == null &&
        !sessionCleanupModel.isOnDevice
