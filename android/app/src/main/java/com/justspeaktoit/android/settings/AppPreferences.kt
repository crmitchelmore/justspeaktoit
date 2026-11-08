package com.justspeaktoit.android.settings

import android.content.Context
import androidx.core.content.edit
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.Retention

/** Non-secret choices. Secrets live in the Keystore-backed `SecretStore`, never here. */
class AppPreferences(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("jsti_prefs", Context.MODE_PRIVATE)

    var chosenMode: RecognitionMode?
        get() {
            val name = prefs.getString(KEY_MODE, null) ?: return null
            return RecognitionMode.entries.firstOrNull { it.name == name }
        }
        set(value) = prefs.edit { if (value == null) remove(KEY_MODE) else putString(KEY_MODE, value.name) }

    var cloudModelId: String?
        get() = prefs.getString(KEY_CLOUD_MODEL, null)
        set(value) = prefs.edit { putString(KEY_CLOUD_MODEL, value) }

    var cleanupEnabled: Boolean
        get() = prefs.getBoolean(KEY_CLEANUP, false)
        set(value) = prefs.edit { putBoolean(KEY_CLEANUP, value) }

    var retention: Retention
        get() {
            val name = prefs.getString(KEY_RETENTION, null)
            return Retention.entries.firstOrNull { it.name == name } ?: Retention.Month
        }
        set(value) = prefs.edit { putString(KEY_RETENTION, value.name) }

    private companion object {
        const val KEY_RETENTION = "history_retention"
        const val KEY_MODE = "chosen_mode"
        const val KEY_CLOUD_MODEL = "cloud_model"
        const val KEY_CLEANUP = "cleanup_enabled"
    }
}
