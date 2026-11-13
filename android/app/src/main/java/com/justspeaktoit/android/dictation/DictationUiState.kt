package com.justspeaktoit.android.dictation

import android.net.Uri
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudProvider
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceHold
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationProfile
import java.util.Locale

data class SharedAudioOffer(val uri: Uri, val mimeType: String?)

/** Optional OpenRouter cleanup of a final transcript. A failure keeps the original text. */
enum class CleanupStatus { None, Running, Applied, Failed }

data class DictationUiState(
    val dictation: DictationState = DictationState.Idle,
    val options: List<ModeAvailability> = emptyList(),
    /** The user's explicit choice; null means "use the best available on-device or device mode". */
    val chosenMode: RecognitionMode? = null,
    /** The saved `DictationLanguages` choice; [languageTag] is what it resolves to now. */
    val languageId: String = DictationLanguages.AUTOMATIC,
    val languageTag: String = Locale.getDefault().toLanguageTag(),
    val onDeviceLanguageTag: String = languageTag,
    val checkingAvailability: Boolean = true,
    val cloudModel: CloudModel = CloudCatalog.defaultTranscriptionModel,
    val savedKeys: Set<CloudProvider> = emptySet(),
    val cleanupEnabled: Boolean = false,
    val cleanupModel: CleanupModel = CloudCatalog.cleanupModel(null),
    val cleanup: CleanupStatus = CleanupStatus.None,
    val originalTranscript: String? = null,
    /** Set when a key could not be saved or removed securely. */
    val keyStoreError: Boolean = false,
    /** Providers whose key last failed to save, be read or be accepted, for the Errors filter. */
    val keyErrors: Set<CloudProvider> = emptySet(),
    /** True until a discarded recording has released the microphone. */
    val releasingMicrophone: Boolean = false,
    /** A Cloud recording paused while another app holds audio focus. */
    val paused: Boolean = false,
    /** Newest first. */
    val history: List<HistoryEntry> = emptyList(),
    val retention: Retention = Retention.Month,
    /** The last history change could not be written; it is retried with the next change. */
    val historyError: Boolean = false,
    /** Audio another app shared, waiting for the user to confirm the upload. */
    val sharedAudio: SharedAudioOffer? = null,
    /** Cancelled Cloud recordings are kept in History for a later transcription. */
    val keepAudioOnCancel: Boolean = AppPreferences.DEFAULT_KEEP_AUDIO_ON_CANCEL,
    /** The History entry whose kept audio is being transcribed, if any. */
    val transcribingEntryId: String? = null,
    /** Personal corrections, in the order they apply. */
    val corrections: List<CorrectionRule> = emptyList(),
    /** System resources the app holds now, oldest first (#1473). */
    val resourcesInUse: List<SystemResourceHold> = emptyList(),
    /** The user's base cleanup prompt; null means the built-in one. */
    val cleanupPrompt: String? = null,
    /** Every saved profile, in the user's order. */
    val profiles: List<DictationProfile> = emptyList(),
    /** The active profile; its choices override the user's own for new sessions. */
    val profile: DictationProfile? = null,
) {
    /** The cloud model a new Cloud session uses: the profile's, else the user's. */
    val sessionCloudModel: CloudModel get() = profile?.cloudModel ?: cloudModel

    val sessionCleanupEnabled: Boolean get() = profile?.cleanupEnabled ?: cleanupEnabled

    val sessionCleanupModel: CleanupModel get() = profile?.cleanupModel ?: cleanupModel

    /** The base cleanup prompt a session uses: the profile's, else the user's, else null for the built-in one. */
    val sessionCleanupPrompt: String?
        get() = profile?.prompt ?: cleanupPrompt?.takeIf { it.isNotBlank() }

    /** The mode a new session would use. */
    val activeMode: RecognitionMode?
        get() = chosenMode ?: RecognizerAvailability.defaultMode(options)

    /** While a session runs, its own mode, so a refresh can never relabel its privacy. */
    val displayedMode: RecognitionMode?
        get() = when (dictation) {
            is DictationState.Starting -> dictation.mode
            is DictationState.Listening -> dictation.mode
            is DictationState.Finishing -> dictation.mode
            else -> activeMode
        }

    val activeAvailability: ModeAvailability?
        get() = options.firstOrNull { it.mode == displayedMode }

    /** Starting waits for a coherent availability result for the current language. */
    val canStart: Boolean
        get() = !dictation.isActive && !checkingAvailability && !releasingMicrophone &&
            cleanup != CleanupStatus.Running && options.firstOrNull { it.mode == activeMode }?.usable == true

    /** Cleanup runs only when switched on (by the profile or the user) and its model's provider has a key. */
    val cleanupReady: Boolean
        get() = sessionCleanupEnabled && sessionCleanupModel.provider in savedKeys
}

/** Deadlines and polling for the session's blocking work; tests shorten them. */
internal data class DictationTimings(
    val transcribeMs: Long = 180_000L,
    val cleanupMs: Long = 60_000L,
    val importMs: Long = 60_000L,
    val downloadCheckIntervalMs: Long = 5_000L,
    val downloadChecks: Int = 60,
)
