package com.justspeaktoit.android.telemetry

import android.content.Context
import androidx.core.content.edit
import com.justspeaktoit.android.settings.AppPreferences

/** [TelemetryStore] on the app's SharedPreferences. Consent keys are the shared settings keys. */
class TelemetryPreferences(context: Context) : TelemetryStore {
    private val prefs = context.applicationContext.getSharedPreferences(AppPreferences.FILE_NAME, Context.MODE_PRIVATE)

    override var analyticsConsent: AnalyticsConsent
        get() = AnalyticsConsent.fromRaw(prefs.getString(AppPreferences.KEY_ANALYTICS_CONSENT, null))
        set(value) = prefs.edit { putString(AppPreferences.KEY_ANALYTICS_CONSENT, value.raw) }

    override var diagnosticsConsent: DiagnosticsConsent
        get() = DiagnosticsConsent.fromRaw(prefs.getString(AppPreferences.KEY_DIAGNOSTICS_CONSENT, null))
        set(value) = prefs.edit { putString(AppPreferences.KEY_DIAGNOSTICS_CONSENT, value.raw) }

    override var analyticsInstallationId: String?
        get() = prefs.getString(ANALYTICS_ID, null)
        set(value) = prefs.edit { if (value == null) remove(ANALYTICS_ID) else putString(ANALYTICS_ID, value) }

    override var lastActiveDay: String?
        get() = prefs.getString(LAST_ACTIVE_DAY, null)
        set(value) = prefs.edit { if (value == null) remove(LAST_ACTIVE_DAY) else putString(LAST_ACTIVE_DAY, value) }

    override var firstSeenDay: String?
        get() = prefs.getString(FIRST_SEEN_DAY, null)
        set(value) = prefs.edit { if (value == null) remove(FIRST_SEEN_DAY) else putString(FIRST_SEEN_DAY, value) }

    override var firstTranscriptionSent: Boolean
        get() = prefs.getBoolean(FIRST_TRANSCRIPTION_SENT, false)
        set(value) = prefs.edit { putBoolean(FIRST_TRANSCRIPTION_SENT, value) }

    private companion object {
        // Internal state, not settings, so these are not indexed by settings search.
        const val ANALYTICS_ID = "analytics.installationId"
        const val LAST_ACTIVE_DAY = "analytics.lastActiveDay"
        const val FIRST_SEEN_DAY = "analytics.firstSeenDay"
        const val FIRST_TRANSCRIPTION_SENT = "analytics.firstTranscriptionSucceeded.emitted"
    }
}
