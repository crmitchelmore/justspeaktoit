package com.justspeaktoit.android.settings

import android.content.Context
import androidx.core.content.edit
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.Retention

/** The non-secret choices the dictation screen reads and writes; [AppPreferences] in production. */
interface DictationPreferences {
    var chosenMode: RecognitionMode?
    var cloudModelId: String?
    var cleanupEnabled: Boolean
    var retention: Retention
    var keepAudioOnCancel: Boolean
}

/** Non-secret choices. Secrets live in the Keystore-backed `SecretStore`, never here. */
class AppPreferences(context: Context) : DictationPreferences {
    private val prefs = context.applicationContext.getSharedPreferences("jsti_prefs", Context.MODE_PRIVATE)

    override var chosenMode: RecognitionMode?
        get() {
            val name = prefs.getString(KEY_MODE, null) ?: return null
            return RecognitionMode.entries.firstOrNull { it.name == name }
        }
        set(value) = prefs.edit { if (value == null) remove(KEY_MODE) else putString(KEY_MODE, value.name) }

    override var cloudModelId: String?
        get() = prefs.getString(KEY_CLOUD_MODEL, null)
        set(value) = prefs.edit { putString(KEY_CLOUD_MODEL, value) }

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

    companion object {
        /** The canonical cross-platform key, shared with the Mac, iOS, Windows and Linux apps. */
        const val KEY_KEEP_AUDIO_ON_CANCEL = "keepAudioOnCancel"
        const val DEFAULT_KEEP_AUDIO_ON_CANCEL = true
        private const val KEY_RETENTION = "history_retention"
        private const val KEY_MODE = "chosen_mode"
        private const val KEY_CLOUD_MODEL = "cloud_model"
        private const val KEY_CLEANUP = "cleanup_enabled"
    }
}
