package com.justspeaktoit.android.settings

import android.content.Context
import androidx.core.content.edit
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.SilenceSettings
import com.justspeaktoit.android.history.Retention
import org.json.JSONObject

/** The non-secret choices the dictation screen reads and writes; [AppPreferences] in production. */
interface DictationPreferences {
    var chosenMode: RecognitionMode?
    var cloudModelId: String?
    var cleanupModelId: String?
    var cleanupEnabled: Boolean
    var retention: Retention
    var keepAudioOnCancel: Boolean

    /** A `DictationLanguages` identifier; null until chosen, which means Automatic. */
    var languageId: String?
    var corrections: List<CorrectionRule>

    /** The user's base cleanup prompt; null or blank means the built-in one. */
    var cleanupPrompt: String?

    /** Named sets of session settings, in the order the user sees them. */
    var profiles: List<DictationProfile>

    /** The chosen [DictationProfile.id], or null for none. */
    var activeProfileId: String?
    var recordingSounds: RecordingSoundSettings

    /** Whether, and after how long, a Cloud recording stops on silence. */
    var silence: SilenceSettings
}

/** Non-secret choices. Secrets live in the Keystore-backed `SecretStore`, never here. */
class AppPreferences(context: Context) : DictationPreferences {
    private val prefs = context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    override var chosenMode: RecognitionMode?
        get() {
            val name = prefs.getString(KEY_MODE, null) ?: return null
            return RecognitionMode.entries.firstOrNull { it.name == name }
        }
        set(value) = prefs.edit { if (value == null) remove(KEY_MODE) else putString(KEY_MODE, value.name) }

    override var cloudModelId: String?
        get() = prefs.getString(KEY_CLOUD_MODEL, null)
        set(value) = prefs.edit { putString(KEY_CLOUD_MODEL, value) }

    /** Null until chosen; existing installs keep the default OpenRouter cleanup route. */
    override var cleanupModelId: String?
        get() = prefs.getString(KEY_CLEANUP_MODEL, null)
        set(value) = prefs.edit { putString(KEY_CLEANUP_MODEL, value) }

    override var cleanupEnabled: Boolean
        get() = prefs.getBoolean(KEY_CLEANUP, false)
        set(value) = prefs.edit { putBoolean(KEY_CLEANUP, value) }

    override var retention: Retention
        get() {
            val name = prefs.getString(KEY_RETENTION, null)
            return Retention.entries.firstOrNull { it.name == name } ?: Retention.Month
        }
        set(value) = prefs.edit { putString(KEY_RETENTION, value.name) }

    /**
     * Cloud mode only: on-device and speech-service recognition never give the app an audio file,
     * so there is nothing to keep when they are cancelled.
     */
    override var keepAudioOnCancel: Boolean
        get() = prefs.getBoolean(KEY_KEEP_AUDIO_ON_CANCEL, DEFAULT_KEEP_AUDIO_ON_CANCEL)
        set(value) = prefs.edit { putBoolean(KEY_KEEP_AUDIO_ON_CANCEL, value) }

    override var languageId: String?
        get() = prefs.getString(KEY_LANGUAGE, null)
        set(value) = prefs.edit { putString(KEY_LANGUAGE, value) }

    override var corrections: List<CorrectionRule>
        get() = PersonalCorrections.decode(prefs.getString(KEY_CORRECTIONS, null))
        set(value) = prefs.edit { putString(KEY_CORRECTIONS, PersonalCorrections.encode(value)) }

    override var cleanupPrompt: String?
        get() = prefs.getString(KEY_CLEANUP_PROMPT, null)
        set(value) = prefs.edit {
            if (value.isNullOrBlank()) remove(KEY_CLEANUP_PROMPT) else putString(KEY_CLEANUP_PROMPT, value)
        }

    override var profiles: List<DictationProfile>
        get() = DictationProfiles.decode(prefs.getString(KEY_PROFILES, null))
        set(value) = prefs.edit { putString(KEY_PROFILES, DictationProfiles.encode(value)) }

    override var activeProfileId: String?
        get() = prefs.getString(KEY_ACTIVE_PROFILE, null)
        set(value) = prefs.edit { if (value == null) remove(KEY_ACTIVE_PROFILE) else putString(KEY_ACTIVE_PROFILE, value) }
    /**
     * Settings another platform owns, from an applied raw configuration, as a JSON object. Kept so the
     * next export still carries them; the app never reads them.
     */
    var otherPlatformSettings: Map<String, Any?>
        get() = prefs.getString(KEY_OTHER_PLATFORM_SETTINGS, null)
            ?.let { runCatching { RawConfiguration.plain(JSONObject(it)) as? Map<*, *> }.getOrNull() }
            ?.mapKeys { it.key.toString() }
            .orEmpty()
        set(value) = prefs.edit { putString(KEY_OTHER_PLATFORM_SETTINGS, RawConfiguration.encode(value)) }

    override var recordingSounds: RecordingSoundSettings
        get() = RecordingSoundSettings(
            enabled = prefs.getBoolean(KEY_SOUNDS_ENABLED, RecordingSoundSettings.DEFAULT_ENABLED),
            profile = RecordingSoundProfile.fromId(prefs.getString(KEY_SOUND_PROFILE, null)),
            volume = prefs.getFloat(KEY_SOUND_VOLUME, RecordingSoundSettings.DEFAULT_VOLUME).coerceIn(0f, 1f),
        )
        set(value) = prefs.edit {
            putBoolean(KEY_SOUNDS_ENABLED, value.enabled)
            putString(KEY_SOUND_PROFILE, value.profile.id)
            putFloat(KEY_SOUND_VOLUME, value.volume.coerceIn(0f, 1f))
        }

    override var silence: SilenceSettings
        get() = SilenceSettings.of(
            enabled = prefs.getBoolean(KEY_SILENCE_ENABLED, false),
            threshold = prefs.getFloat(KEY_SILENCE_THRESHOLD, SilenceSettings.DEFAULT_THRESHOLD.toFloat()).toDouble(),
            durationSeconds = prefs.getFloat(KEY_SILENCE_DURATION, SilenceSettings.DEFAULT_DURATION.toFloat()).toDouble(),
        )
        set(value) = prefs.edit {
            putBoolean(KEY_SILENCE_ENABLED, value.enabled)
            putFloat(KEY_SILENCE_THRESHOLD, value.threshold.toFloat())
            putFloat(KEY_SILENCE_DURATION, value.durationSeconds.toFloat())
        }

    companion object {
        const val FILE_NAME = "jsti_prefs"

        /** Product analytics consent (`telemetry.AnalyticsConsent`); absent means not asked, so off. */
        const val KEY_ANALYTICS_CONSENT = "analyticsConsent"

        /** Crash-report consent (`telemetry.DiagnosticsConsent`), the key the Mac and iOS apps use. */
        const val KEY_DIAGNOSTICS_CONSENT = "diagnosticsConsent"

        /** The canonical cross-platform key, shared with the Mac, iOS, Windows and Linux apps. */
        const val KEY_KEEP_AUDIO_ON_CANCEL = "keepAudioOnCancel"
        const val DEFAULT_KEEP_AUDIO_ON_CANCEL = true
        private const val KEY_RETENTION = "history_retention"
        private const val KEY_MODE = "chosen_mode"
        private const val KEY_CLOUD_MODEL = "cloud_model"
        private const val KEY_CLEANUP = "cleanup_enabled"
        private const val KEY_CLEANUP_MODEL = "cleanup_model"

        /** The canonical cross-platform key; values are SpeakCore `TranscriptionLanguageCatalog` IDs. */
        private const val KEY_LANGUAGE = "preferredLocale"
        private const val KEY_CORRECTIONS = "personal_corrections"

        /** Canonical cross-platform keys, shared with the desktop apps and SpeakCore's profile store. */
        private const val KEY_CLEANUP_PROMPT = "postProcessingSystemPrompt"
        const val KEY_PROFILES = "dictationProfiles"
        private const val KEY_ACTIVE_PROFILE = "activeDictationProfileID"
        private const val KEY_OTHER_PLATFORM_SETTINGS = "raw_configuration_other_platform_settings"
        /** The canonical cross-platform recording sound keys, shared with the Mac, Windows and Linux apps. */
        private const val KEY_SOUNDS_ENABLED = "recordingSoundsEnabled"
        private const val KEY_SOUND_PROFILE = "recordingSoundProfile"
        private const val KEY_SOUND_VOLUME = "recordingSoundVolume"

        /** Canonical cross-platform keys (SpeakCore `ApplicationPreferenceKey`). */
        private const val KEY_SILENCE_ENABLED = "silenceDetectionEnabled"
        private const val KEY_SILENCE_THRESHOLD = "silenceThreshold"
        private const val KEY_SILENCE_DURATION = "silenceDuration"
    }
}
